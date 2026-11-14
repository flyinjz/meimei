// The bottom strip (the Mac's StatusBarView): library totals, what's shown,
// the selection, and import progress.
import QtQuick
import I2S

GlassSurface {
    id: status
    element: "statusBar"
    fallback: Skin.bgPanel
    property int selectionCount: 0
    readonly property real baseHeight: (Core.settings.density === "compact" ? 18 : Core.settings.density === "spacious" ? 25 : 20) + 6
    height: style.height === undefined ? baseHeight : style.height

    function longDuration(seconds) {
        const minutes = Math.floor(seconds / 60)
        if (minutes < 60) return minutes + " min"
        const h = Math.floor(minutes / 60), m = minutes % 60
        return m === 0 ? h + " hr" : h + " hr " + m + " min"
    }

    component Divider: Rectangle { width: 1; height: 10; color: Skin.hairline; anchors.verticalCenter: parent ? parent.verticalCenter : undefined }

    Row {
        x: 14; anchors.verticalCenter: parent.verticalCenter
        spacing: 12
        Label { pt: 10.5; weight: "semibold"; role: "statusText"; text: Library.count + " tracks"; color: Skin.textSecondary }
        Divider {}
        Label { pt: 10.5; weight: "semibold"; role: "statusText"; text: status.longDuration(Library.totalDuration); color: Skin.textSecondary }
        Divider {}
        Label { pt: 10.5; role: "statusText"; text: Library.visibleCount + " shown"; color: Skin.textTertiary }
        Divider { visible: Library.scanning }
        ProgressLine {
            visible: Library.scanning; width: 80; height: 3; anchors.verticalCenter: parent.verticalCenter
            fraction: Library.scanTotal > 0 ? Library.scanDone / Library.scanTotal : -1
        }
        Label {
            visible: Library.scanning; pt: 10.5; role: "statusText"; color: Skin.accent
            text: Library.scanTotal === 0 ? "Looking in " + Library.scanLabel + "…" : "Importing " + Library.scanDone + " of " + Library.scanTotal
        }
        Divider { visible: status.selectionCount > 0 && Core.settings.statusBarShowSelectionCount !== false }
        Label {
            visible: status.selectionCount > 0 && Core.settings.statusBarShowSelectionCount !== false
            pt: 10.5; role: "statusText"; text: status.selectionCount + " selected"; color: Skin.accent
        }
    }
}
