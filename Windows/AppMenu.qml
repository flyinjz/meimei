pragma Singleton
// i2s's own menus in place of the platform's (the Mac's AppMenu): a
// borderless popup per level (root, then one per open submenu), driven from
// the keyboard and mouse like a native menu. A click outside only
// dismisses; Escape closes a level; arrows move and open/close submenus;
// Return/Enter/Space activate; typing a letter jumps to the next entry
// starting with it. Content format: see MenuView.
import QtQuick
import QtQuick.Window
import I2S

QtObject {
    id: menu
    property var levels: []
    readonly property bool isOpen: levels.length > 0

    /// Opens `content` with its top-left at a global point, flipping to stay on screen.
    function open(content, gx, gy, minWidth) {
        close()
        if (!content || Platform.headless) return
        openLevel(content, 0, minWidth || 0, (w, h, s) => {
            let x = gx, y = gy
            if (x + w > s.x + s.w) x = gx - w
            if (y + h > s.y + s.h) y = gy - h
            return clamp(x, y, w, h, s)
        })
    }

    /// Opens `content` under `item`, as a dropdown at least as wide as it.
    function openBelow(item, content) {
        close()
        if (!content || !item || Platform.headless) return
        const p = item.mapToGlobal(0, 0)
        openLevel(content, 0, item.width, (w, h, s) => {
            let x = p.x, y = p.y + item.height + 4
            if (y + h > s.y + s.h) y = p.y - 4 - h
            return clamp(x, y, w, h, s)
        })
    }

    function close() { closeFrom(0) }

    function closeFrom(depth) {
        const keep = levels.slice(0, depth)
        for (const l of levels.slice(depth)) { l.visible = false; l.destroy() }
        levels = keep
        if (keep.length) keep[keep.length - 1].requestActivate()
    }

    function screenAt(x, y) {
        for (const s of Qt.application.screens)
            if (x >= s.virtualX && x < s.virtualX + s.width && y >= s.virtualY && y < s.virtualY + s.height)
                return { x: s.virtualX, y: s.virtualY, w: s.width, h: s.height }
        const s = Qt.application.screens[0]
        return { x: s.virtualX, y: s.virtualY, w: s.width, h: s.height }
    }

    function clamp(x, y, w, h, s) {
        return Qt.point(Math.min(Math.max(x, s.x + 4), s.x + s.w - w - 4), Math.min(Math.max(y, s.y + 4), s.y + s.h - h - 4))
    }

    function openLevel(content, depth, minWidth, place) {
        const win = levelComponent.createObject(null, { content: content, depth: depth, minWidth: minWidth })
        const size = Qt.size(win.view.implicitWidth, win.view.implicitHeight)
        win.width = size.width; win.height = size.height
        const probe = place(size.width, size.height, screenAt(win.x, win.y))
        const s = screenAt(probe.x, probe.y)
        const at = place(size.width, size.height, s)
        win.x = at.x; win.y = at.y
        Platform.setupPopup(win, Skin.isGlass)
        levels = levels.concat([win])
        win.show()
        win.requestActivate()
        return win
    }

    function hover(level, index, row) {
        level.highlighted = index
        const e = index >= 0 ? level.view.entries[index] : null
        const enabled = e && (e.enabled === undefined || e.enabled)
        if (!e || !e.submenu || !enabled) {
            // Pointing at a plain row closes any submenu opened from this level.
            if (levels.length > level.depth + 1) closeFrom(level.depth + 1)
            return
        }
        const next = levels[level.depth + 1]
        if (next && next.source === index) return
        closeFrom(level.depth + 1)
        const top = row.mapToGlobal(0, 0).y
        const parentLeft = level.x, parentRight = level.x + level.width
        const sub = openLevel(e.submenu, level.depth + 1, 0, (w, h, s) => {
            let x = parentRight - 1, y = top - 4
            if (x + w > s.x + s.w) x = parentLeft - w + 1
            return clamp(x, y, w, h, s)
        })
        sub.source = index
    }

    function activate(level, index, row) {
        const e = level.view.entries[index]
        if (!e || (e.enabled !== undefined && !e.enabled)) return
        if (e.submenu) {
            hover(level, index, row)
            const next = levels[level.depth + 1]
            if (next) next.highlighted = next.firstEnabled(0, 1)
            return
        }
        close()
        // After the menu is gone, so windows the action opens present cleanly.
        if (e.action) Qt.callLater(e.action)
    }

    function key(level, event) {
        const v = level.view, n = v.entries.length
        const step = (from, dir) => level.firstEnabled(from, dir)
        switch (event.key) {
        case Qt.Key_Escape: levels.length > 1 ? closeFrom(levels.length - 1) : close(); break
        case Qt.Key_Down: level.highlighted = step(level.highlighted + 1, 1); break
        case Qt.Key_Up: level.highlighted = step(level.highlighted < 0 ? n - 1 : level.highlighted - 1, -1); break
        case Qt.Key_Right:
            if (level.highlighted >= 0 && v.entries[level.highlighted].submenu) activate(level, level.highlighted, v.rowItem(level.highlighted))
            break
        case Qt.Key_Left: if (levels.length > 1) closeFrom(levels.length - 1); break
        case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_Space:
            if (level.highlighted >= 0) activate(level, level.highlighted, v.rowItem(level.highlighted))
            break
        default: {
            const ch = (event.text || "").toLowerCase()
            if (!/^[a-z0-9]$/.test(ch)) break
            for (let k = 1; k <= n; ++k) {
                const i = (Math.max(level.highlighted, -1) + k) % n
                const e = v.entries[i]
                if ((e.enabled === undefined || e.enabled) && e.title.toLowerCase().startsWith(ch)) { level.highlighted = i; break }
            }
        }
        }
        event.accepted = true
    }

    property Component levelComponent: Component {
        Window {
            id: win
            property var content
            property int depth: 0
            property real minWidth: 0
            property int source: -1
            property alias highlighted: view.highlighted
            readonly property alias view: view
            flags: Qt.Popup | Qt.FramelessWindowHint
            color: "transparent"
            onActiveChanged: if (!active && depth === 0 && menu.levels.indexOf(win) >= 0 && menu.levels.every(l => !l.active)) Qt.callLater(() => { if (menu.levels.every(l => !l.active)) menu.close() })
            function firstEnabled(from, dir) {
                const n = view.entries.length
                for (let k = 0; k < n; ++k) {
                    const i = ((from + dir * k) % n + n) % n
                    const e = view.entries[i]
                    if (e.enabled === undefined || e.enabled) return i
                }
                return -1
            }
            Item {
                anchors.fill: parent
                focus: true
                Keys.onPressed: (event) => menu.key(win, event)
                MenuView {
                    id: view
                    content: win.content
                    minWidth: win.minWidth
                    width: parent.width; height: parent.height
                    // The Mac's appear: from 97% and 3 points up, fading in over 0.13 s.
                    transformOrigin: Item.TopLeft
                    opacity: 0; scale: 0.97
                    Component.onCompleted: { opacity = 1; scale = 1 }
                    Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutQuad } }
                    Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutQuad } }
                    onHovered: (index, row) => menu.hover(win, index, row)
                    onActivated: (index, row) => menu.activate(win, index, row)
                }
            }
        }
    }
}
