// An exact SwiftUI spring (mass 1, stiffness (2π/response)², damping
// 4π·dampingFraction/response), solved in closed form and stepped once per
// displayed frame. Retargeting keeps the current velocity, as SwiftUI does.
// Bind `target`; read `value`.
import QtQuick

QtObject {
    id: sp
    property real target: 0
    property real value: 0
    property real response: 0.55
    property real dampingFraction: 0.825
    /// Seconds to wait before moving (staggered lines).
    property real delay: 0
    readonly property bool moving: fa.running
    /// Follows the target at once (no motion) while true.
    property bool instant: false

    property real _from: 0
    property real _v0: 0
    property real _t: 0
    property real _lastX: 0
    property real _lastT: 0
    property bool _ready: false

    Component.onCompleted: { value = target; _ready = true }
    onTargetChanged: {
        if (!_ready) return
        if (instant) { fa.running = false; value = target; return }
        // Velocity now (from the last step), carried into the new motion.
        const v = fa.running && _t - _lastT > 0 ? (value - _lastX) / (_t - _lastT) : 0
        _from = value; _v0 = fa.running ? v : 0; _t = fa.running ? 0 : -delay; _lastX = value; _lastT = 0
        fa.running = true
    }

    property FrameAnimation fa: FrameAnimation {
        onTriggered: {
            sp._lastX = sp.value; sp._lastT = sp._t
            sp._t += frameTime
            if (sp._t < 0) return
            const w0 = 2 * Math.PI / sp.response, z = sp.dampingFraction, t = sp._t
            const a = sp._from - sp.target, v = sp._v0
            let x
            if (z >= 1) {
                x = sp.target + (a + (v + w0 * a) * t) * Math.exp(-w0 * t)
            } else {
                const wd = w0 * Math.sqrt(1 - z * z)
                const b = (v + z * w0 * a) / wd
                x = sp.target + Math.exp(-z * w0 * t) * (a * Math.cos(wd * t) + b * Math.sin(wd * t))
            }
            sp.value = x
            if (Math.abs(x - sp.target) < 0.005 * Math.max(1, Math.abs(a)) && t > 0.1) { sp.value = sp.target; running = false }
        }
    }
}
