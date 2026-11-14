#include "MediaSession.h"
#include <QMetaObject>
#include <QPointer>
#include <QWindow>
#include <atomic>
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <windows.media.h>
#include <systemmediatransportcontrolsinterop.h>

using namespace ABI::Windows::Media;
using ABI::Windows::Foundation::ITypedEventHandler;
using ABI::Windows::Foundation::TimeSpan;

namespace {
template <class T> void release(T *&p) { if (p) { p->Release(); p = nullptr; } }

struct HStr {
    HSTRING h = nullptr;
    explicit HStr(const QString &s) { WindowsCreateString(reinterpret_cast<const wchar_t *>(s.utf16()), UINT32(s.size()), &h); }
    ~HStr() { if (h) WindowsDeleteString(h); }
};

TimeSpan span(double seconds) { TimeSpan t; t.Duration = INT64(seconds * 1e7); return t; }

/// A COM object with one Invoke, as WinRT event handlers are.
template <class Iface> struct Handler : Iface {
    std::atomic<ULONG> refs{1};
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (iid == __uuidof(Iface) || iid == IID_IUnknown || iid == IID_IAgileObject) { *out = static_cast<Iface *>(this); AddRef(); return S_OK; }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { const ULONG n = --refs; if (!n) delete this; return n; }
    virtual ~Handler() = default;
};
}

using ButtonIface = ITypedEventHandler<SystemMediaTransportControls *, SystemMediaTransportControlsButtonPressedEventArgs *>;
using SeekIface = ITypedEventHandler<SystemMediaTransportControls *, PlaybackPositionChangeRequestedEventArgs *>;

// Windows calls these on its own thread; the session is reached on Qt's.
struct ButtonHandler : Handler<ButtonIface> {
    QPointer<MediaSession> session;
    HRESULT STDMETHODCALLTYPE Invoke(ISystemMediaTransportControls *, ISystemMediaTransportControlsButtonPressedEventArgs *args) override {
        SystemMediaTransportControlsButton b;
        if (FAILED(args->get_Button(&b))) return S_OK;
        const int which = int(b);
        QMetaObject::invokeMethod(session, [s = session, which] { if (s) s->button(which); }, Qt::QueuedConnection);
        return S_OK;
    }
};

struct SeekHandler : Handler<SeekIface> {
    QPointer<MediaSession> session;
    HRESULT STDMETHODCALLTYPE Invoke(ISystemMediaTransportControls *, IPlaybackPositionChangeRequestedEventArgs *args) override {
        TimeSpan t;
        if (FAILED(args->get_RequestedPlaybackPosition(&t))) return S_OK;
        const double seconds = double(t.Duration) / 1e7;
        QMetaObject::invokeMethod(session, [s = session, seconds] { if (s) emit s->seekRequested(seconds); }, Qt::QueuedConnection);
        return S_OK;
    }
};

MediaSession *MediaSession::instance() {
    static MediaSession *s = new MediaSession;
    return s;
}

MediaSession::MediaSession(QObject *parent) : QObject(parent) {}

MediaSession::~MediaSession() {
    auto *smtc = static_cast<ISystemMediaTransportControls *>(m_smtc);
    if (!smtc) return;
    EventRegistrationToken t;
    t.value = m_buttonToken;
    smtc->remove_ButtonPressed(t);
    ISystemMediaTransportControls2 *two = nullptr;
    if (SUCCEEDED(smtc->QueryInterface(__uuidof(ISystemMediaTransportControls2), reinterpret_cast<void **>(&two)))) {
        t.value = m_seekToken;
        two->remove_PlaybackPositionChangeRequested(t);
        two->Release();
    }
    static_cast<ButtonHandler *>(m_buttonHandler)->Release();
    if (m_seekHandler) static_cast<SeekHandler *>(m_seekHandler)->Release();
    smtc->Release();
}

bool MediaSession::attach(QWindow *window) {
    if (m_smtc || !window) return m_smtc != nullptr;
    RoInitialize(RO_INIT_SINGLETHREADED);  // Qt's GUI thread is already STA; this is a no-op then
    ISystemMediaTransportControlsInterop *interop = nullptr;
    HStr cls(QStringLiteral("Windows.Media.SystemMediaTransportControls"));
    if (FAILED(RoGetActivationFactory(cls.h, __uuidof(ISystemMediaTransportControlsInterop), reinterpret_cast<void **>(&interop)))) return false;
    ISystemMediaTransportControls *smtc = nullptr;
    const HRESULT hr = interop->GetForWindow(reinterpret_cast<HWND>(window->winId()), __uuidof(ISystemMediaTransportControls), reinterpret_cast<void **>(&smtc));
    interop->Release();
    if (FAILED(hr) || !smtc) return false;
    smtc->put_IsEnabled(true);
    smtc->put_IsPlayEnabled(true);
    smtc->put_IsPauseEnabled(true);
    smtc->put_IsStopEnabled(true);
    smtc->put_IsNextEnabled(true);
    smtc->put_IsPreviousEnabled(true);
    smtc->put_PlaybackStatus(MediaPlaybackStatus_Closed);

    auto *buttons = new ButtonHandler;
    buttons->session = this;
    EventRegistrationToken token{};
    smtc->add_ButtonPressed(buttons, &token);
    m_buttonToken = token.value;
    m_buttonHandler = buttons;

    ISystemMediaTransportControls2 *two = nullptr;
    if (SUCCEEDED(smtc->QueryInterface(__uuidof(ISystemMediaTransportControls2), reinterpret_cast<void **>(&two)))) {
        auto *seek = new SeekHandler;
        seek->session = this;
        two->add_PlaybackPositionChangeRequested(seek, &token);
        m_seekToken = token.value;
        m_seekHandler = seek;
        two->Release();
    }
    m_smtc = smtc;
    emit activeChanged();
    return true;
}

void MediaSession::button(int which) {
    switch (which) {
    case SystemMediaTransportControlsButton_Play: emit playRequested(); break;
    case SystemMediaTransportControlsButton_Pause: emit pauseRequested(); break;
    case SystemMediaTransportControlsButton_Stop: emit stopRequested(); break;
    case SystemMediaTransportControlsButton_Next: emit nextRequested(); break;
    case SystemMediaTransportControlsButton_Previous: emit previousRequested(); break;
    default: break;
    }
}

void MediaSession::setPlaying(bool playing) {
    m_status = playing ? MediaPlaybackStatus_Playing : MediaPlaybackStatus_Paused;
    if (auto *smtc = static_cast<ISystemMediaTransportControls *>(m_smtc)) smtc->put_PlaybackStatus(MediaPlaybackStatus(m_status));
}

void MediaSession::setStopped() {
    m_status = MediaPlaybackStatus_Closed;
    if (auto *smtc = static_cast<ISystemMediaTransportControls *>(m_smtc)) smtc->put_PlaybackStatus(MediaPlaybackStatus_Closed);
}

void MediaSession::setTrack(const QString &title, const QString &artist, const QString &album, const QString &albumArtist) {
    m_title = title; m_artist = artist; m_album = album;
    auto *smtc = static_cast<ISystemMediaTransportControls *>(m_smtc);
    if (!smtc) return;
    ISystemMediaTransportControlsDisplayUpdater *updater = nullptr;
    if (FAILED(smtc->get_DisplayUpdater(&updater))) return;
    updater->put_Type(MediaPlaybackType_Music);
    IMusicDisplayProperties *music = nullptr;
    if (SUCCEEDED(updater->get_MusicProperties(&music))) {
        HStr t(title), a(artist), aa(albumArtist);
        music->put_Title(t.h);
        music->put_Artist(a.h);
        music->put_AlbumArtist(aa.h);
        IMusicDisplayProperties2 *two = nullptr;
        if (SUCCEEDED(music->QueryInterface(__uuidof(IMusicDisplayProperties2), reinterpret_cast<void **>(&two)))) {
            HStr al(album);
            two->put_AlbumTitle(al.h);
            two->Release();
        }
        music->Release();
    }
    updater->Update();
    updater->Release();
}

void MediaSession::setTimeline(double position, double duration) {
    m_position = position; m_duration = duration;
    auto *smtc = static_cast<ISystemMediaTransportControls *>(m_smtc);
    if (!smtc) return;
    ISystemMediaTransportControls2 *two = nullptr;
    if (FAILED(smtc->QueryInterface(__uuidof(ISystemMediaTransportControls2), reinterpret_cast<void **>(&two)))) return;
    IInspectable *inst = nullptr;
    HStr cls(QStringLiteral("Windows.Media.SystemMediaTransportControlsTimelineProperties"));
    if (SUCCEEDED(RoActivateInstance(cls.h, &inst))) {
        ISystemMediaTransportControlsTimelineProperties *tl = nullptr;
        if (SUCCEEDED(inst->QueryInterface(__uuidof(ISystemMediaTransportControlsTimelineProperties), reinterpret_cast<void **>(&tl)))) {
            tl->put_StartTime(span(0));
            tl->put_MinSeekTime(span(0));
            tl->put_EndTime(span(duration));
            tl->put_MaxSeekTime(span(duration));
            tl->put_Position(span(position));
            two->UpdateTimelineProperties(tl);
            tl->Release();
        }
        inst->Release();
    }
    two->Release();
}

void MediaSession::setCanGoNext(bool can) {
    if (auto *smtc = static_cast<ISystemMediaTransportControls *>(m_smtc)) smtc->put_IsNextEnabled(can);
}

void MediaSession::setCanGoPrevious(bool can) {
    if (auto *smtc = static_cast<ISystemMediaTransportControls *>(m_smtc)) smtc->put_IsPreviousEnabled(can);
}

QString MediaSession::describe() const {
    auto *smtc = static_cast<ISystemMediaTransportControls *>(m_smtc);
    if (!smtc) return QStringLiteral("inactive");
    MediaPlaybackStatus status;
    smtc->get_PlaybackStatus(&status);
    const char *names[] = {"closed", "changing", "stopped", "playing", "paused"};
    return QStringLiteral("status %1; %2 — %3 (%4); %5 / %6 s")
        .arg(names[qBound(0, int(status), 4)], m_title, m_artist, m_album)
        .arg(m_position, 0, 'f', 1).arg(m_duration, 0, 'f', 1);
}
