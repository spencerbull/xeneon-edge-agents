import QtQuick
import "PortalPalette.js" as Palette

Item {
    id: root

    property bool active: false
    property bool reducedMotion: false
    property var agents: []
    property var health: ({})
    property var voice: ({})
    property string connectionState: "reconnecting"
    property real revealProgress: active ? 1 : 0
    property real orbitPhase: 0.125
    property real orbitBoostPhase: 0
    property real motionEnergy: 0
    property real frozenBoostPhase: 0
    property real exitCoastPhase: 0
    property bool exitShield: false

    readonly property int entryDurationMs: 1350
    readonly property int exitDurationMs: 1000
    readonly property int nodeLimit: 6
    readonly property int visibleAgentCount: Math.min(
        nodeLimit,
        agents.length
    )
    readonly property string mode: Palette.ambientMode(
        agents,
        voice,
        connectionState
    )
    readonly property color modeAccent: mode === "off"
        ? "#55e9ff"
        : Palette.ambientColor(mode)
    readonly property bool orbiting: !reducedMotion
        && (active || exitShield || revealProgress > 0)
    readonly property real curtainProgress: stage(
        revealProgress,
        0,
        0.34
    )
    readonly property real ringProgress: easeOut(stage(
        revealProgress,
        0.18,
        0.62
    ))
    readonly property real centerProgress: easeOut(stage(
        revealProgress,
        0.3,
        0.72
    ))
    readonly property real nodeProgress: easeOut(stage(
        revealProgress,
        0.52,
        1
    ))
    readonly property real controlCenterProgress:
        controlCenterProgressAt(revealProgress, active)
    readonly property real effectiveBoostPhase: active
        ? orbitBoostPhase * motionEnergy
        : frozenBoostPhase + exitCoastPhase

    signal wakeRequested()

    visible: active || revealProgress > 0 || exitShield
    enabled: active || exitShield
    z: 40

    Accessible.role: Accessible.Button
    Accessible.name: "Wake agent portal"
    Accessible.onPressAction: {
        if (root.active)
            root.wakeRequested()
    }

    Behavior on revealProgress {
        NumberAnimation {
            duration: root.reducedMotion
                ? 0
                : (root.active
                    ? root.entryDurationMs
                    : root.exitDurationMs)
            easing.type: root.active ? Easing.InOutCubic : Easing.Linear
        }
    }

    NumberAnimation on orbitPhase {
        running: root.orbiting
        from: 0
        to: 1
        duration: 180000
        loops: Animation.Infinite
    }

    NumberAnimation on orbitBoostPhase {
        running: root.orbiting && root.motionEnergy > 0.001
        from: 0
        to: 1
        duration: 22000
        loops: Animation.Infinite
    }

    SequentialAnimation {
        id: motionRamp

        running: root.active && !root.reducedMotion

        PropertyAction {
            target: root
            property: "motionEnergy"
            value: 0
        }

        PauseAnimation {
            duration: 2800
        }

        NumberAnimation {
            target: root
            property: "motionEnergy"
            from: 0
            to: 1
            duration: 1600
            easing.type: Easing.InOutCubic
        }
    }

    NumberAnimation {
        id: exitMotionDrain

        target: root
        property: "motionEnergy"
        to: 0
        duration: 220
        easing.type: Easing.OutCubic
    }

    NumberAnimation {
        id: exitOrbitCoast

        target: root
        property: "exitCoastPhase"
        from: 0
        to: 0.012
        duration: 220
        easing.type: Easing.OutCubic
    }

    Timer {
        id: exitShieldTimer

        interval: root.exitDurationMs + 80
        repeat: false
        onTriggered: {
            root.exitShield = false
            root.motionEnergy = 0
            root.orbitBoostPhase = 0
            root.frozenBoostPhase = 0
            root.exitCoastPhase = 0
        }
    }

    onActiveChanged: {
        if (active) {
            exitMotionDrain.stop()
            exitOrbitCoast.stop()
            frozenBoostPhase = 0
            exitCoastPhase = 0
            exitShield = false
            exitShieldTimer.stop()
        } else {
            frozenBoostPhase = orbitBoostPhase * motionEnergy
            exitCoastPhase = 0
            exitShield = !reducedMotion
            if (exitShield) {
                exitMotionDrain.from = motionEnergy
                exitMotionDrain.restart()
                exitOrbitCoast.restart()
                exitShieldTimer.restart()
            } else {
                motionEnergy = 0
                orbitBoostPhase = 0
                frozenBoostPhase = 0
            }
        }
    }

    onReducedMotionChanged: {
        if (reducedMotion) {
            exitMotionDrain.stop()
            exitOrbitCoast.stop()
            exitShieldTimer.stop()
            exitShield = false
            orbitPhase = 0.125
            orbitBoostPhase = 0
            motionEnergy = 0
            frozenBoostPhase = 0
            exitCoastPhase = 0
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "#020711"
        opacity: root.curtainProgress
    }

    Item {
        id: constellation

        width: 1540
        height: 560
        anchors.centerIn: parent

        Repeater {
            model: 5

            Rectangle {
                required property int index

                readonly property real diameter:
                    300 + index * 152

                width: diameter
                height: diameter
                radius: diameter / 2
                anchors.centerIn: parent
                scale: 0.8 + root.ringProgress * 0.2
                color: "transparent"
                border.width: index === 4 ? 2 : 1
                border.color: Qt.alpha(
                    index % 2 === 0 ? root.modeAccent : "#7a65ff",
                    0.1 + (4 - index) * 0.025
                )
                opacity: root.ringProgress
            }
        }

        Repeater {
            model: root.visibleAgentCount

            OrbitTrail {
                required property int index

                anchors.fill: parent
                centerX: constellation.width / 2
                centerY: constellation.height / 2
                radiusX: root.radiusXFor(index)
                radiusY: root.radiusYFor(index)
                angleDegrees: root.nodeAngleDegrees(index)
                accent: Palette.agentColor(root.agents[index])
                reveal: root.nodeProgress
                    * (0.08 + root.motionEnergy * 0.92)
                sweepDegrees: 34
                    + root.motionEnergy * (30 + index * 3)
            }
        }

        Repeater {
            model: root.visibleAgentCount

            AmbientAgentNode {
                required property int index

                objectName: "ambientAgentNode-" + index
                agent: root.agents[index]
                centerX: constellation.width / 2
                centerY: constellation.height / 2
                radiusX: root.radiusXFor(index)
                radiusY: root.radiusYFor(index)
                angleDegrees: root.nodeAngleDegrees(index)
                reveal: root.nodeProgress
                reducedMotion: root.reducedMotion
            }
        }

        Item {
            id: centerCore

            width: 330
            height: 330
            anchors.centerIn: parent
            opacity: root.centerProgress
            scale: 0.82 + root.centerProgress * 0.18

            Rectangle {
                anchors {
                    fill: parent
                    margins: -22
                }
                radius: width / 2
                color: "transparent"
                border.width: 2
                border.color: Qt.alpha(root.modeAccent, 0.14)
            }

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: "#d9060c16"
                border.width: 2
                border.color: Qt.alpha(root.modeAccent, 0.54)
            }

            Rectangle {
                id: centerPulse

                anchors.centerIn: parent
                width: parent.width - 28
                height: parent.height - 28
                radius: width / 2
                color: "transparent"
                border.width: 2
                border.color: Qt.alpha(root.modeAccent, 0.32)

                SequentialAnimation on opacity {
                    running: root.orbiting && root.mode !== "off"
                    loops: Animation.Infinite

                    NumberAnimation {
                        from: 0.34
                        to: 0.95
                        duration: root.mode === "voice-recording"
                            ? 560
                            : 1100
                        easing.type: Easing.InOutSine
                    }

                    NumberAnimation {
                        from: 0.95
                        to: 0.34
                        duration: root.mode === "voice-recording"
                            ? 560
                            : 1100
                        easing.type: Easing.InOutSine
                    }
                }
            }

            Column {
                anchors.centerIn: parent
                spacing: 10

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.centerTitle()
                    textFormat: Text.PlainText
                    color: root.modeAccent
                    font {
                        family: "monospace"
                        pixelSize: 34
                        weight: Font.Light
                        letterSpacing: 8
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.centerDetail()
                    textFormat: Text.PlainText
                    color: "#7e9bb4"
                    font {
                        family: "monospace"
                        pixelSize: 13
                        weight: Font.DemiBold
                        letterSpacing: 1.2
                    }
                }
            }
        }
    }

    Text {
        anchors {
            horizontalCenter: parent.horizontalCenter
            bottom: parent.bottom
            bottomMargin: 30
        }
        text: "TOUCH TO WAKE"
        textFormat: Text.PlainText
        color: "#7892ad"
        opacity: root.nodeProgress
        font {
            family: "monospace"
            pixelSize: 13
            letterSpacing: 2
        }
    }

    TapHandler {
        enabled: root.enabled
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: {
            if (root.active)
                root.wakeRequested()
        }
    }

    function stage(value, start, end) {
        if (end <= start)
            return value >= end ? 1 : 0
        return Math.max(0, Math.min(1, (value - start) / (end - start)))
    }

    function easeOut(value) {
        return 1 - Math.pow(1 - value, 3)
    }

    function controlCenterProgressAt(value, entering) {
        if (root.reducedMotion)
            return entering ? 0 : 1
        if (entering)
            return 1 - easeOut(stage(value, 0, 0.22))
        return easeOut(stage(1 - value, 0.58, 1))
    }

    function speedFor(index) {
        // Integer multipliers ensure every shared phase reset is an exact
        // number of full turns, so no node or trail can jump at a loop.
        return [1, 2, 1, 3, 2, 1][index % nodeLimit]
    }

    function baseAngleFor(index) {
        return [-88, -30, 30, 92, 154, 214][index % nodeLimit]
    }

    function radiusXFor(index) {
        return [410, 530, 650, 470, 600, 510][index % nodeLimit]
    }

    function radiusYFor(index) {
        return [152, 205, 174, 238, 214, 188][index % nodeLimit]
    }

    function nodeAngleDegrees(index) {
        return baseAngleFor(index)
            + orbitPhase * 360 * speedFor(index)
            + effectiveBoostPhase * 360 * speedFor(index)
    }

    function centerTitle() {
        if (mode.indexOf("voice-") === 0)
            return "VOICE"
        if (mode === "error")
            return "ATTENTION"
        return "AMBIENT"
    }

    function centerDetail() {
        if (mode !== "off")
            return Palette.ambientLabel(mode)
        return agents.length + " AGENTS // "
            + String(health.status || "UNKNOWN").toUpperCase()
    }
}
