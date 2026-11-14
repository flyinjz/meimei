// A text field in the app's look (the Mac's DialogTextField): a faint fill,
// a hairline, no system chrome.
import QtQuick
import I2S

Item {
    id: root
    property alias text: input.text
    property string placeholder: ""
    property real pt: 12
    property alias input: input
    property real fieldHeight: 28
    property real padding: 11
    signal accepted()

    implicitHeight: fieldHeight
    implicitWidth: 200

    Rectangle {
        anchors.fill: parent
        color: Skin.withAlpha(Skin.textPrimary, 0.07)
        border.width: 0.5
        border.color: Qt.rgba(1, 1, 1, 0.06)
    }
    TextInput {
        id: input
        anchors { left: parent.left; right: parent.right; leftMargin: root.padding; rightMargin: root.padding; verticalCenter: parent.verticalCenter }
        font: Type.font(root.pt, "regular")
        color: Skin.textPrimary
        selectionColor: Skin.withAlpha(Skin.accent, 0.45)
        selectedTextColor: Skin.textPrimary
        renderType: Text.NativeRendering
        clip: true
        selectByMouse: true
        onAccepted: root.accepted()
        Label {
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text === "" && !input.preeditText
            pt: root.pt
            text: root.placeholder
            color: Skin.textTertiary
        }
    }
}
