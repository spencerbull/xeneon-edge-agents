import QtQuick
import "../state/ThemePalette.js" as ThemePalette

Rectangle {
    id: root

    property string label: ""
    property string stateLabel: ""
    property var theme: ThemePalette.fallback
    property color accent: theme.accent
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
        ? theme.surfacePressed
        : checked
            ? Qt.alpha(accent, 0.12)
            : theme.surfaceRaised
    border.width: 1
    border.color: checked
        ? Qt.alpha(accent, 0.78)
        : theme.border

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
            color: root.checked ? root.accent : root.theme.textMuted

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
                color: root.theme.textPrimary
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
                color: root.checked
                    ? ThemePalette.ensureContrast(
                        String(root.accent),
                        String(root.theme.surfaceRaised),
                        4.5
                    )
                    : root.theme.textMuted
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
