// The app's progress line (the Mac's CapsuleProgress): a thin solid line.
// Determinate: glides between updates over the time since the last one, so
// it moves continuously instead of jumping. Indeterminate (fraction < 0): a
// segment runs along the track, stretching as it speeds up and shortening
// as it slows, then starts again. Square ends, no gradient, no glow. The
// glide runs on the render thread (an animator), as the Mac's runs on the
// render server.
import QtQuick
import I2S

Item {
    id: root
    /// 0…1, or negative for indeterminate.
    property real fraction: -1
    /// The fill; ink by default.
    property color tint: Skin.withAlpha(Skin.textPrimary, 0.85)
    readonly property bool indeterminate: fraction < 0
    readonly property real clamped: Math.min(1, Math.max(0, fraction))

    implicitHeight: 3
    clip: true

    Rectangle { anchors.fill: parent; color: Skin.withAlpha(Skin.textPrimary, 0.1) }

    // Determinate: a full-width bar slid in from the left; moving it is an
    // XAnimator, so it glides on the render thread.
    Rectangle {
        id: bar
        visible: !root.indeterminate
        width: root.width; height: root.height
        color: root.tint
        property real last: -1
        property double lastAt: 0
        function follow() {
            const target = -root.width * (1 - root.clamped)
            const now = Date.now() / 1000
            const since = now - lastAt
            lastAt = now
            // Going back (a restart), the first move after a pause, or no
            // width yet: no glide.
            if (Platform.forceFallback || last < 0 || root.clamped < last || since >= 2 || root.width <= 0) {
                glide.stop(); x = target
            } else {
                glide.stop()
                glide.from = x; glide.to = target
                glide.duration = Math.min(600, Math.max(150, since * 1000))
                glide.start()
            }
            last = root.clamped
        }
        XAnimator {
            id: glide
            target: bar
            // The Mac's (0.25, 0.1, 0.4, 1): eases out so consecutive glides join.
            easing.type: Easing.Bezier
            easing.bezierCurve: [0.25, 0.1, 0.4, 1, 1, 1]
        }
    }
    onClampedChanged: if (!indeterminate) bar.follow()
    onWidthChanged: if (!indeterminate) { bar.last = -1; bar.follow() }
    onIndeterminateChanged: if (!indeterminate) { bar.last = -1; bar.follow() }

    // Indeterminate: enters short from the left, stretches to about a third
    // mid-run, leaves short on the right; 1.6 s a run.
    Rectangle {
        id: runner
        visible: root.indeterminate
        height: root.height
        color: root.tint
        // Snapshots get a still frame, as on the Mac.
        x: Platform.forceFallback ? root.width * 0.36 : 0
        width: Platform.forceFallback ? root.width * 0.28 : 0
        SequentialAnimation {
            running: root.indeterminate && !Platform.forceFallback && root.visible && root.width > 0
            loops: Animation.Infinite
            readonly property real w: root.width
            ParallelAnimation {
                NumberAnimation { target: runner; property: "x"; from: -0.08 * root.width; to: 0.12 * root.width; duration: 480; easing.type: Easing.Bezier; easing.bezierCurve: [0.45, 0, 0.25, 1, 1, 1] }
                NumberAnimation { target: runner; property: "width"; from: 0.08 * root.width; to: 0.34 * root.width; duration: 480; easing.type: Easing.Bezier; easing.bezierCurve: [0.45, 0, 0.25, 1, 1, 1] }
            }
            ParallelAnimation {
                NumberAnimation { target: runner; property: "x"; to: 0.62 * root.width; duration: 720; easing.type: Easing.Bezier; easing.bezierCurve: [0.45, 0, 0.25, 1, 1, 1] }
                NumberAnimation { target: runner; property: "width"; to: 0.26 * root.width; duration: 720; easing.type: Easing.Bezier; easing.bezierCurve: [0.45, 0, 0.25, 1, 1, 1] }
            }
            ParallelAnimation {
                NumberAnimation { target: runner; property: "x"; to: root.width; duration: 400; easing.type: Easing.Bezier; easing.bezierCurve: [0.45, 0, 0.25, 1, 1, 1] }
                NumberAnimation { target: runner; property: "width"; to: 0.04 * root.width; duration: 400; easing.type: Easing.Bezier; easing.bezierCurve: [0.45, 0, 0.25, 1, 1, 1] }
            }
        }
    }
}
