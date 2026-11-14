// Mouse-wheel glide (the Mac's SmoothWheel): a wheel notch moves the view
// the distance the platform scrolls for it (Windows' wheel lines × the
// view's line height), eased out over 0.16 s; notches in quick succession
// add to where the glide is heading. Precision touchpads (deltas that aren't
// whole notches) move the view directly, as the Mac leaves trackpads alone.
// Put it inside a Flickable or ListView.
import QtQuick

WheelHandler {
    id: handler
    /// The view this scrolls: the Flickable it's declared in (handlers
    /// declared in a Flickable land in its content item).
    property Flickable view: parent instanceof Flickable ? parent : parent.parent
    /// Height of one line, in points (a table's row height).
    property real line: 16
    readonly property real duration: 0.16
    readonly property bool gliding: anim.running
    property real targetY: 0
    property real targetX: 0

    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    target: null

    function maxY() { return Math.max(view.originY, view.originY + view.contentHeight - view.height) }
    function maxX() { return Math.max(view.originX, view.originX + view.contentWidth - view.width) }

    onWheel: (event) => {
        const lines = Qt.styleHints.wheelScrollLines
        const dy = event.angleDelta.y, dx = event.angleDelta.x
        const notched = dy % 120 === 0 && dx % 120 === 0 && event.pixelDelta.x === 0 && event.pixelDelta.y === 0
        if (!notched) {
            // Fine-grained input: follow it exactly, no glide.
            anim.stop()
            const py = event.pixelDelta.y !== 0 ? event.pixelDelta.y : dy / 120 * lines * line
            const px = event.pixelDelta.x !== 0 ? event.pixelDelta.x : dx / 120 * lines * line
            view.contentY = Math.max(view.originY, Math.min(maxY(), view.contentY - py))
            view.contentX = Math.max(view.originX, Math.min(maxX(), view.contentX - px))
            event.accepted = true
            return
        }
        const fromY = anim.running ? targetY : view.contentY
        const fromX = anim.running ? targetX : view.contentX
        const ty = Math.max(view.originY, Math.min(maxY(), fromY - dy / 120 * lines * line))
        const tx = Math.max(view.originX, Math.min(maxX(), fromX - dx / 120 * lines * line))
        event.accepted = true
        if (ty === view.contentY && tx === view.contentX && !anim.running) return
        targetY = ty; targetX = tx
        // Restart from where the view is now toward the new target.
        anim.stop()
        yAnim.from = view.contentY; yAnim.to = ty
        xAnim.from = view.contentX; xAnim.to = tx
        anim.start()
    }

    property ParallelAnimation anim: ParallelAnimation {
        NumberAnimation { id: yAnim; target: handler.view; property: "contentY"; duration: handler.duration * 1000; easing.type: Easing.OutCubic }
        NumberAnimation { id: xAnim; target: handler.view; property: "contentX"; duration: handler.duration * 1000; easing.type: Easing.OutCubic }
    }
}
