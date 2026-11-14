#pragma once
// The platform pieces of a window, as the Mac's WindowChromeGuard and
// PlatformBehindWindowBlur: i2s's own square, borderless frame that still
// resizes from its edges, snaps and casts the system shadow; the blur of
// whatever is behind the window (the theme's veil is drawn in QML on top);
// minimize, full screen and zoom for the window buttons.
#include <QObject>
#include <QAbstractNativeEventFilter>
#include <QSet>
#include <QQuickWindow>
#include <QJSEngine>
#include <qqmlintegration.h>

class Platform : public QObject, public QAbstractNativeEventFilter {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    /// Offscreen snapshots can't capture the platform blur (as the Mac's
    /// GlassRendering.forceFallback): glass draws its stand-in instead.
    Q_PROPERTY(bool forceFallback READ forceFallback CONSTANT)
    /// Which behind-window blur glass windows get: "acrylic" (our own tint
    /// over the system acrylic blur), "blur" (plain blur), "system" (the
    /// system's transient acrylic material) or "none".
    Q_PROPERTY(QString blurKind READ blurKind CONSTANT)
    /// Windows are never shown (tests); menus don't open.
    Q_PROPERTY(bool headless READ headless CONSTANT)
public:
    static Platform *instance();
    static Platform *create(class QQmlEngine *, class QJSEngine *) { auto *p = instance(); QJSEngine::setObjectOwnership(p, QJSEngine::CppOwnership); return p; }

    bool forceFallback() const { return m_fallback; }
    void setForceFallback(bool on) { m_fallback = on; }
    QString blurKind() const { return m_blur; }
    void setBlurKind(const QString &k) { m_blur = k; }
    /// Windows are never shown (tests): set before any window is created.
    void setHeadless(bool on) { m_headless = on; }
    bool headless() const { return m_headless; }

    /// Gives a window i2s's frame; `glass` makes it see-through with the blur behind.
    Q_INVOKABLE void setup(QQuickWindow *window, bool glass);
    /// A popup (menu) window: square, no frame, the blur behind it when `glass`.
    Q_INVOKABLE void setupPopup(QQuickWindow *window, bool glass);
    Q_INVOKABLE void minimize(QWindow *window);
    /// Full screen; with `zoom` (Alt-click, the Mac's Option-click) maximize instead.
    Q_INVOKABLE void toggleFullScreen(QWindow *window, bool zoom = false);
    /// Starts moving the window with the pointer (title bands): keeps Aero snap.
    Q_INVOKABLE void startMove(QWindow *window);
    /// Whether the Alt key is down (the Mac's Option).
    Q_INVOKABLE bool altDown() const;

    bool nativeEventFilter(const QByteArray &type, void *message, qintptr *result) override;

private:
    explicit Platform(QObject *parent = nullptr);
    void applyBlur(void *hwnd, bool glass);
    QSet<void *> m_framed;
    bool m_fallback = false;
    bool m_headless = false;
    QString m_blur = QStringLiteral("acrylic");
};
