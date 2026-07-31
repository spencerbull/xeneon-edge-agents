import QtQuick
import "PortalPalette.js" as Palette

Item {
    id: root

    required property var agent
    property real centerX: 0
    property real centerY: 0
    property real radiusX: 320
    property real radiusY: 170
    property real angleDegrees: 0
    property real reveal: 0
    property bool reducedMotion: false
    property real glowPulse: 0.55

    readonly property string agentState:
        Palette.effectiveAgentState(agent)
    readonly property color accent: Palette.agentColor(agent)
    readonly property real angleRadians: angleDegrees * Math.PI / 180
    readonly property bool pulsing: !reducedMotion
        && reveal > 0
        && (agentState === "working" || agentState === "blocked")

    width: 216
    height: 80
    x: centerX + Math.cos(angleRadians) * radiusX - width / 2
    y: centerY + Math.sin(angleRadians) * radiusY - height / 2
    opacity: reveal
    scale: 0.78 + reveal * 0.22

    SequentialAnimation on glowPulse {
        running: root.pulsing
        loops: Animation.Infinite

        NumberAnimation {
            from: 0.42
            to: 1
            duration: root.agentState === "blocked" ? 560 : 980
            easing.type: Easing.InOutSine
        }

        NumberAnimation {
            from: 1
            to: 0.42
            duration: root.agentState === "blocked" ? 560 : 980
            easing.type: Easing.InOutSine
        }
    }

    Rectangle {
        anchors {
            fill: parent
            margins: -12
        }
        radius: height / 2
        color: "transparent"
        border.width: 2
        border.color: Qt.alpha(root.accent, 0.12)
        opacity: root.pulsing ? root.glowPulse : 0.62
    }

    Rectangle {
        anchors {
            fill: parent
            margins: -6
        }
        radius: height / 2
        color: Qt.alpha(root.accent, 0.04)
        border.width: 2
        border.color: Qt.alpha(root.accent, 0.28)
        opacity: root.pulsing ? 0.48 + root.glowPulse * 0.4 : 0.72
    }

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: "#ed08111d"
        border.width: 2
        border.color: root.accent
    }

    Rectangle {
        anchors {
            left: parent.left
            leftMargin: 18
            verticalCenter: parent.verticalCenter
        }
        width: 10
        height: 10
        radius: 5
        color: root.accent
        opacity: root.agentState === "idle" ? 0.62 : 1
    }

    Text {
        objectName: "ambientAgentDisplayName"
        anchors {
            left: parent.left
            leftMargin: 38
            right: parent.right
            rightMargin: 18
            verticalCenter: parent.verticalCenter
        }
        text: String(root.agent.display_name || "AGENT").toUpperCase()
        textFormat: Text.PlainText
        color: "#e7f8ff"
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        font {
            family: "monospace"
            pixelSize: 16
            weight: Font.DemiBold
            letterSpacing: 0.8
        }
    }

    Behavior on opacity {
        NumberAnimation {
            duration: root.reducedMotion ? 0 : 260
            easing.type: Easing.OutCubic
        }
    }

    Behavior on scale {
        NumberAnimation {
            duration: root.reducedMotion ? 0 : 420
            easing.type: Easing.OutBack
        }
    }
}
