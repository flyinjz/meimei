#include "Platform.h"
#include <QCoreApplication>
#include <QGuiApplication>
#include <QQuickWindow>
#include <QSurfaceFormat>
#include <windows.h>
#include <windowsx.h>
#include <dwmapi.h>

namespace {
// Undocumented but stable since Windows 10: the accent policy behind every
// shell surface's blur. Used for a blur without the system's grey tint.
enum AccentState { AccentDisabled = 0, AccentBlurBehind = 3, AccentAcrylicBlurBehind = 4 };
struct AccentPolicy { int state; int flags; DWORD gradientColor; int animationId; };
struct CompositionData { int attribute; void *data; SIZE_T size; };
using SetCompositionFn = BOOL(WINAPI *)(HWND, CompositionData *);
constexpr int WcaAccentPolicy = 19;

void setAccent(HWND hwnd, int state, DWORD abgr) {
    static auto set = reinterpret_cast<SetCompositionFn>(
        reinterpret_cast<void *>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetWindowCompositionAttribute")));
    if (!set) return;
    AccentPolicy policy{state, state == AccentAcrylicBlurBehind ? 0 : 0, abgr, 0};
    CompositionData data{WcaAccentPolicy, &policy, sizeof(policy)};
    set(hwnd, &data);
}
}

Platform *Platform::instance() {
    static Platform *p = new Platform;
    return p;
}

Platform::Platform(QObject *parent) : QObject(parent) {
    QCoreApplication::instance()->installNativeEventFilter(this);
}

void Platform::setup(QQuickWindow *window, bool glass) {
    if (!window) return;
    if (glass && !m_fallback) {
        QSurfaceFormat fmt = window->format();
        fmt.setAlphaBufferSize(8);
        window->setFormat(fmt);
        window->setColor(Qt::transparent);
    }
    if (m_headless) return;
    HWND hwnd = reinterpret_cast<HWND>(window->winId());
    m_framed.insert(hwnd);
    // A real resizable frame for the shell (snap, shadow, edge resize), with
    // the client area covering all of it (WM_NCCALCSIZE below).
    LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
    style |= WS_THICKFRAME | WS_CAPTION | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU;
    SetWindowLongPtrW(hwnd, GWL_STYLE, style);
    DWORD corner = 1;  // DWMWCP_DONOTROUND: square, as on the Mac
    DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, &corner, sizeof(corner));
    BOOL dark = TRUE;
    DwmSetWindowAttribute(hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof(dark));
    COLORREF none = 0xFFFFFFFE;  // DWMWA_COLOR_NONE: no accent-coloured border line
    DwmSetWindowAttribute(hwnd, 34 /* DWMWA_BORDER_COLOR */, &none, sizeof(none));
    applyBlur(hwnd, glass);
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0, SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

void Platform::setupPopup(QQuickWindow *window, bool glass) {
    if (!window || m_headless) return;
    if (glass && !m_fallback) {
        QSurfaceFormat fmt = window->format();
        fmt.setAlphaBufferSize(8);
        window->setFormat(fmt);
        window->setColor(Qt::transparent);
    }
    HWND hwnd = reinterpret_cast<HWND>(window->winId());
    DWORD corner = 1;  // square
    DwmSetWindowAttribute(hwnd, 33, &corner, sizeof(corner));
    BOOL dark = TRUE;
    DwmSetWindowAttribute(hwnd, 20, &dark, sizeof(dark));
    if (glass && !m_fallback && m_blur != "none") {
        if (m_blur == "blur") setAccent(hwnd, AccentBlurBehind, 0);
        else setAccent(hwnd, AccentAcrylicBlurBehind, 0x01000000);
    }
}

void Platform::applyBlur(void *h, bool glass) {
    HWND hwnd = static_cast<HWND>(h);
    // A one-pixel frame margin keeps the system shadow on an opaque window;
    // glass windows extend the frame across the whole client area.
    MARGINS margins = glass ? MARGINS{-1, -1, -1, -1} : MARGINS{0, 0, 0, 1};
    DwmExtendFrameIntoClientArea(hwnd, &margins);
    if (!glass || m_blur == "none") return;
    if (m_blur == "system") {
        DWORD backdrop = 3;  // DWMSBT_TRANSIENTWINDOW (acrylic)
        DwmSetWindowAttribute(hwnd, 38 /* DWMWA_SYSTEMBACKDROP_TYPE */, &backdrop, sizeof(backdrop));
    } else if (m_blur == "blur") {
        setAccent(hwnd, AccentBlurBehind, 0);
    } else {
        // Acrylic's blur with an almost clear tint: the theme's veil in QML
        // does the darkening, so the desktop's colour comes through clean.
        setAccent(hwnd, AccentAcrylicBlurBehind, 0x01000000);
    }
}

void Platform::minimize(QWindow *window) {
    if (window) window->showMinimized();
}

void Platform::toggleFullScreen(QWindow *window, bool zoom) {
    if (!window) return;
    if (zoom) {
        window->windowStates() & Qt::WindowMaximized ? window->showNormal() : window->showMaximized();
    } else {
        window->windowStates() & Qt::WindowFullScreen ? window->showNormal() : window->showFullScreen();
    }
}

void Platform::startMove(QWindow *window) {
    if (window) window->startSystemMove();
}

bool Platform::altDown() const { return QGuiApplication::queryKeyboardModifiers() & Qt::AltModifier; }

bool Platform::nativeEventFilter(const QByteArray &, void *message, qintptr *result) {
    MSG *msg = static_cast<MSG *>(message);
    if (!m_framed.contains(msg->hwnd)) return false;
    if (msg->message == WM_NCCALCSIZE && msg->wParam == TRUE) {
        // Client area = whole window. A maximized window hangs its frame off
        // the monitor's edges, so pull the client back inside.
        if (IsZoomed(msg->hwnd)) {
            auto *params = reinterpret_cast<NCCALCSIZE_PARAMS *>(msg->lParam);
            const UINT dpi = GetDpiForWindow(msg->hwnd);
            const int frame = GetSystemMetricsForDpi(SM_CXFRAME, dpi) + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
            params->rgrc[0].left += frame; params->rgrc[0].right -= frame;
            params->rgrc[0].top += frame; params->rgrc[0].bottom -= frame;
        }
        *result = 0;
        return true;
    }
    if (msg->message == WM_NCHITTEST) {
        if (IsZoomed(msg->hwnd) || (GetWindowLongPtrW(msg->hwnd, GWL_STYLE) & WS_THICKFRAME) == 0) { *result = HTCLIENT; return true; }
        RECT r;
        GetWindowRect(msg->hwnd, &r);
        const int x = GET_X_LPARAM(msg->lParam), y = GET_Y_LPARAM(msg->lParam);
        const int b = MulDiv(6, GetDpiForWindow(msg->hwnd), 96);
        const bool L = x < r.left + b, R = x >= r.right - b, T = y < r.top + b, B = y >= r.bottom - b;
        *result = T && L ? HTTOPLEFT : T && R ? HTTOPRIGHT : B && L ? HTBOTTOMLEFT : B && R ? HTBOTTOMRIGHT
                : L ? HTLEFT : R ? HTRIGHT : T ? HTTOP : B ? HTBOTTOM : HTCLIENT;
        return true;
    }
    return false;
}
