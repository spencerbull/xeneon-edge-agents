import QtQuick

Rectangle {
    id: root

    property string label: ""
    property string stateLabel: ""
    property color accent: "#55e9ff"
    property bool checked: false

    signal toggled()

    function activate() {
        if (!enabled)
            return false
        toggled()
        return true
    }

    radius: 13
    color: settingTap.pressed
        ? "#17283a"
        : checked
            ? Qt.alpha(accent, 0.12)
            : "#0b1523"
    border.width: 1
    border.color: checked
        ? Qt.alpha(accent, 0.78)
        : "#34506b"

    Accessible.role: Accessible.Button
    Accessible.ignored: !enabled
    Accessible.name: label
    Accessible.description: stateLabel
    Accessible.checkable: true
    Accessible.checked: checked
    Accessible.onPressAction: activate()

    Row {
        anchors.centerIn: parent
        spacing: 8

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 9
            height: 9
            radius: width / 2
            color: root.checked ? root.accent : "#526b82"

            Rectangle {
                anchors {
                    fill: parent
                    margins: -4
                }
                radius: width / 2
                color: "transparent"
                border.width: root.checked ? 1 : 0
                border.color: Qt.alpha(root.accent, 0.32)
            }
        }

        Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            Text {
                text: root.label
                textFormat: Text.PlainText
                color: "#e8f8fc"
                font {
                    family: "monospace"
                    pixelSize: 11
                    weight: Font.Bold
                    letterSpacing: 0.6
                }
            }

            Text {
                text: root.stateLabel
                textFormat: Text.PlainText
                color: root.checked ? root.accent : "#7892aa"
                font {
                    family: "monospace"
                    pixelSize: 8
                    weight: Font.DemiBold
                    letterSpacing: 0.5
                }
            }
        }
    }

    TapHandler {
        id: settingTap

        enabled: root.enabled
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: root.activate()
    }
}
