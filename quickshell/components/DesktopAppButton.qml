import QtQuick
import "../state/ThemePalette.js" as ThemePalette

Rectangle {
    id: root

    property string label: ""
    property string detail: "OPEN / FOCUS"
    property var theme: ThemePalette.fallback
    property color accent: theme.accent
    property bool pending: false
    signal triggered()
    signal interacted()

    radius: 14
    color: tapHandler.pressed ? theme.surfacePressed : theme.surfaceRaised
    border.width: 1
    border.color: Qt.alpha(accent, pending ? 0.35 : 0.62)
    opacity: enabled ? 1 : 0.42

    function activate() {
        if (!root.enabled || root.pending)
            return false
        interacted()
        triggered()
        return true
    }

    Accessible.role: Accessible.Button
    Accessible.ignored: !root.enabled
    Accessible.name: label
    Accessible.description: pending ? "Action in progress" : detail
    Accessible.onPressAction: root.activate()

    Column {
        anchors.centerIn: parent
        spacing: 1

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.label
            textFormat: Text.PlainText
            color: root.theme.textPrimary
            font {
                family: "monospace"
                pixelSize: 15
                weight: Font.Bold
                letterSpacing: 0.6
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.pending ? "OPENING" : root.detail
            textFormat: Text.PlainText
            color: ThemePalette.ensureContrast(
                String(root.accent),
                String(root.theme.surfaceRaised),
                4.5
            )
            font {
                family: "monospace"
                pixelSize: 9
                weight: Font.DemiBold
                letterSpacing: 0.7
            }
        }
    }

    TapHandler {
        id: tapHandler
        enabled: root.enabled && !root.pending
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: root.activate()
    }
}
