// A rotary control in the DAW style (the Mac's Knob): drag up/down (Shift
// for fine), wheel, double-click to reset. A 270° arc shows the value;
// bipolar knobs fill from the centre.
import QtQuick
import QtQuick.Shapes
import I2S

Item {
    id: root
    property real value: 0
    property real from: 0
    property real to: 1
    property real defaultValue: 0
    property bool logarithmic: false
    property bool bipolar: false
    property real size: 44
    property color tint: Skin.accent
    signal moved(real value)
    signal began()

    width: size; height: size

    readonly property real fraction: Math.min(1, Math.max(0, logarithmic
        ? Math.log(value / from) / Math.log(to / from)
        : (value - from) / (to - from)))
    property real shownFraction: fraction
    Behavior on shownFraction { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }

    function valueAt(f) {
        f = Math.min(1, Math.max(0, f))
        return logarithmic ? from * Math.pow(to / from, f) : from + f * (to - from)
    }

    readonly property real sweep: 0.75
    readonly property real zero: bipolar ? 0.5 : 0
    // Angles in degrees, 0 = 3 o'clock, clockwise; the arc starts at 135°.
    function arc(f0, f1) { return { start: 135 + f0 * sweep * 360, span: (f1 - f0) * sweep * 360 } }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: Skin.withAlpha(Skin.textPrimary, 0.1); strokeWidth: 3; fillColor: "transparent"; capStyle: ShapePath.RoundCap
            PathAngleArc { centerX: root.size / 2; centerY: root.size / 2; radiusX: root.size / 2 - 1.5; radiusY: radiusX; startAngle: 135; sweepAngle: 270 }
        }
        ShapePath {
            strokeColor: root.tint; strokeWidth: 3; fillColor: "transparent"; capStyle: ShapePath.RoundCap
            PathAngleArc {
                readonly property real f0: Math.min(root.zero, root.shownFraction)
                readonly property real f1: Math.max(root.zero, root.shownFraction)
                centerX: root.size / 2; centerY: root.size / 2; radiusX: root.size / 2 - 1.5; radiusY: radiusX
                startAngle: 135 + f0 * root.sweep * 360; sweepAngle: (f1 - f0) * root.sweep * 360
            }
        }
    }
    Rectangle {
        anchors.centerIn: parent
        width: root.size * 0.64; height: width; radius: width / 2
        color: Skin.withAlpha(Skin.textPrimary, hover.hovered ? 0.11 : 0.07)
    }
    Item {
        anchors.fill: parent
        rotation: -135 + 270 * root.shownFraction
        Rectangle { width: 2; height: root.size * 0.16; x: (root.size - 2) / 2; y: root.size / 2 - root.size * 0.2 - height / 2; color: Skin.textPrimary }
    }

    HoverHandler { id: hover }
    property real dragStart: -1
    DragHandler {
        target: null
        dragThreshold: 1
        onActiveChanged: if (active) { root.dragStart = root.fraction; root.began() } else root.dragStart = -1
        onTranslationChanged: if (active) {
            const fine = (Platform.altDown() || (centroid.modifiers & Qt.ShiftModifier)) ? 0.2 : 1
            root.moved(root.valueAt(root.dragStart - translation.y / 180 * fine))
        }
    }
    TapHandler { onDoubleTapped: { root.began(); root.moved(root.defaultValue) } }
    WheelHandler {
        target: null
        onWheel: (e) => {
            // The Mac's 8 points per wheel line, over 400 points of travel.
            const dy = e.pixelDelta.y !== 0 ? e.pixelDelta.y : e.angleDelta.y / 120 * 8
            if (root.dragStart < 0) root.began()
            root.moved(root.valueAt(root.fraction + dy / 400))
        }
    }
}
