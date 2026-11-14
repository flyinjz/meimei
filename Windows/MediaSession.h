#pragma once
// Media keys and the system's now-playing controls (Windows' System Media
// Transport Controls: the keyboard's media keys, the volume flyout, the
// lock screen and Quick Settings), as Now Playing / MPRemoteCommandCenter on
// the Mac. The player tells it what plays; it tells the player what the
// user pressed.
#include <QObject>
#include <QString>
#include <QWindow>
#include <QJSEngine>
#include <qqmlintegration.h>

class MediaSession : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    /// True once Windows accepted the session for a window.
    Q_PROPERTY(bool active READ active NOTIFY activeChanged)
public:
    static MediaSession *instance();
    static MediaSession *create(class QQmlEngine *, class QJSEngine *) { auto *p = instance(); QJSEngine::setObjectOwnership(p, QJSEngine::CppOwnership); return p; }
    ~MediaSession() override;

    /// Binds the controls to the app's main window (Windows ties them to one).
    Q_INVOKABLE bool attach(QWindow *window);
    bool active() const { return m_smtc != nullptr; }

    Q_INVOKABLE void setPlaying(bool playing);
    /// Nothing is loaded: the controls show "closed".
    Q_INVOKABLE void setStopped();
    Q_INVOKABLE void setTrack(const QString &title, const QString &artist, const QString &album, const QString &albumArtist);
    /// Seconds; call on seeks and track changes (Windows extrapolates while playing).
    Q_INVOKABLE void setTimeline(double position, double duration);
    Q_INVOKABLE void setCanGoNext(bool can);
    Q_INVOKABLE void setCanGoPrevious(bool can);

    /// The session as Windows reports it, for the self-test.
    Q_INVOKABLE QString describe() const;

signals:
    void activeChanged();
    void playRequested();
    void pauseRequested();
    void toggleRequested();
    void stopRequested();
    void nextRequested();
    void previousRequested();
    void seekRequested(double seconds);

private:
    explicit MediaSession(QObject *parent = nullptr);
    void button(int which);
    void *m_smtc = nullptr;       // ISystemMediaTransportControls
    void *m_buttonHandler = nullptr, *m_seekHandler = nullptr;
    qint64 m_buttonToken = 0, m_seekToken = 0;
    QString m_title, m_artist, m_album;
    double m_position = 0, m_duration = 0;
    int m_status = 0;
    friend struct ButtonHandler;
    friend struct SeekHandler;
};
