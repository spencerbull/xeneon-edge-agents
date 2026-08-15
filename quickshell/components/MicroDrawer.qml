import QtQuick
import "PortalPalette.js" as Palette
import "../state/ThemePalette.js" as ThemePalette

Item {
    id: root

    property bool opened: false
    property var theme: ThemePalette.fallback
    property bool reducedMotion: false
    property bool interactive: true
    property var micro: ({"connected": false})
    property var agents: []
    property var voice: ({"state": "unavailable", "owned": false})
    readonly property color connectionColor: micro.connected
        ? theme.green
        : theme.red
    readonly property color readableConnectionColor: readableStateColor(
        connectionColor,
        theme.surface
    )

    signal closeRequested()
    signal interacted()

    function ringState() {
        var voiceState = String(voice.state || "unavailable")
        if (voiceState === "recording")
            return "recording"
        if (voiceState === "processing")
            return "processing"
        if (voiceState === "error")
            return "error"
        var hasWorking = false
        var hasReview = false
        for (var index = 0; index < agents.length; index += 1) {
            var state = Palette.effectiveAgentState(agents[index])
            if (state === "blocked")
                return "blocked"
            if (state === "review")
                hasReview = true
            if (state === "working")
                hasWorking = true
        }
        if (hasReview)
            return "review"
        if (hasWorking)
            return "working"
        return "idle"
    }

    function ringColor() {
        switch (ringState()) {
        case "recording":
            return root.theme.green
        case "processing":
            return root.theme.cyan
        case "error":
            return root.theme.red
        case "blocked":
            return root.theme.yellow
        case "review":
            return root.theme.green
        case "working":
            return root.theme.blue
        default:
            return root.theme.muted
        }
    }

    function readableStateColor(color, background) {
        return ThemePalette.ensureContrast(
            String(color),
            String(background),
            4.5
        )
    }

    visible: opened
    enabled: opened && interactive

    Rectangle {
        anchors {
            left: parent.left
            right: drawer.left
            top: parent.top
            bottom: parent.bottom
        }
        color: Qt.alpha(root.theme.canvas, 0.62)

        TapHandler {
            enabled: root.enabled
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: {
                root.interacted()
                root.closeRequested()
            }
        }
    }

    Rectangle {
        id: drawer

        anchors {
            right: parent.right
            top: parent.top
            bottom: parent.bottom
            topMargin: 98
            bottomMargin: 108
            rightMargin: 24
        }
        width: 720
        radius: 22
        color: Qt.alpha(root.theme.surface, 0.95)
        border.width: 1
        border.color: root.micro.connected
            ? root.theme.borderStrong
            : root.theme.red

        Column {
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                leftMargin: 24
                rightMargin: 24
                topMargin: 20
            }
            spacing: 3

            Text {
                text: "CODEX MICRO // VIRTUAL PROJECTION"
                textFormat: Text.PlainText
                color: root.theme.textPrimary
                font {
                    family: "monospace"
                    pixelSize: 20
                    weight: Font.Bold
                    letterSpacing: 0.8
                }
            }

            Text {
                text: root.micro.connected
                    ? "DEVICE LINK ACTIVE · READ ONLY"
                    : "DEVICE LINK UNAVAILABLE"
                textFormat: Text.PlainText
                color: root.readableConnectionColor
                font {
                    family: "monospace"
                    pixelSize: 11
                    weight: Font.DemiBold
                    letterSpacing: 0.7
                }
            }
        }

        Rectangle {
            id: closeButton

            anchors {
                right: parent.right
                top: parent.top
                rightMargin: 18
                topMargin: 16
            }
            width: 66
            height: 42
            radius: 10
            color: closeTap.pressed
                ? root.theme.surfacePressed
                : root.theme.surfaceRaised
            border.width: 1
            border.color: root.theme.border

            Accessible.role: Accessible.Button
            Accessible.ignored: !root.enabled
            Accessible.name: "Close Codex Micro projection"
            Accessible.onPressAction: {
                if (root.enabled)
                    root.closeRequested()
            }

            Text {
                anchors.centerIn: parent
                text: "CLOSE"
                textFormat: Text.PlainText
                color: root.theme.textSecondary
                font {
                    family: "monospace"
                    pixelSize: 11
                    weight: Font.DemiBold
                }
            }

            TapHandler {
                id: closeTap
                enabled: root.enabled
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: {
                    root.interacted()
                    root.closeRequested()
                }
            }
        }

        Row {
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                bottom: parent.bottom
                leftMargin: 24
                rightMargin: 24
                topMargin: 82
                bottomMargin: 20
            }
            spacing: 22

            Column {
                width: 210
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12

                Rectangle {
                    width: 158
                    height: 158
                    radius: 79
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: root.theme.surface
                    border.width: 10
                    border.color: root.ringColor()

                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        running: !root.reducedMotion
                            && root.opened
                            && ["working", "blocked", "recording"].indexOf(
                                root.ringState()
                            ) !== -1
                        NumberAnimation {
                            from: 0.58
                            to: 1
                            duration: root.ringState() === "blocked" ? 500 : 850
                            easing.type: Easing.InOutSine
                        }
                        NumberAnimation {
                            from: 1
                            to: 0.58
                            duration: root.ringState() === "blocked" ? 500 : 850
                            easing.type: Easing.InOutSine
                        }
                    }

                    Column {
                        anchors.centerIn: parent
                        spacing: 2

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: root.micro.connected
                                ? Number(root.micro.battery) >= 0
                                    ? root.micro.battery + "%"
                                    : "LINK"
                                : "OFF"
                            textFormat: Text.PlainText
                            color: root.theme.textPrimary
                            font {
                                family: "monospace"
                                pixelSize: 27
                                weight: Font.Bold
                            }
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: root.ringState().toUpperCase()
                            textFormat: Text.PlainText
                            color: root.readableStateColor(
                                root.ringColor(),
                                root.theme.surface
                            )
                            font {
                                family: "monospace"
                                pixelSize: 10
                                weight: Font.DemiBold
                                letterSpacing: 0.7
                            }
                        }
                    }
                }

                Text {
                    width: parent.width
                    text: root.micro.connected
                        ? "FW " + String(root.micro.firmware || "—")
                            + "  ·  LAYER " + (
                                Number(root.micro.layer) >= 0
                                    ? root.micro.layer
                                    : "—"
                            )
                            + "  ·  PROFILE " + (
                                Number(root.micro.profile) >= 0
                                    ? root.micro.profile
                                    : "—"
                            )
                        : "WAITING FOR MICROD"
                    textFormat: Text.PlainText
                    color: root.theme.textMuted
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    font {
                        family: "monospace"
                        pixelSize: 10
                    }
                }
            }

            Grid {
                id: slotGrid

                width: parent.width - 232
                height: parent.height
                columns: 2
                columnSpacing: 12
                rowSpacing: 12

                Repeater {
                    model: 6

                    Rectangle {
                        required property int index
                        readonly property var agent:
                            index < root.agents.length
                                ? root.agents[index]
                                : null
                        readonly property color accent:
                            agent === null
                                ? root.theme.border
                                : Palette.agentColor(agent, root.theme)
                        readonly property color readableAccent:
                            root.readableStateColor(
                                accent,
                                root.theme.surfaceRaised
                            )

                        width: (slotGrid.width - slotGrid.columnSpacing) / 2
                        height: (slotGrid.height - slotGrid.rowSpacing * 2) / 3
                        radius: 15
                        color: root.theme.surfaceRaised
                        border.width: 1
                        border.color: Qt.alpha(accent, agent === null ? 0.45 : 0.78)

                        Rectangle {
                            anchors {
                                left: parent.left
                                top: parent.top
                                bottom: parent.bottom
                            }
                            width: 7
                            radius: 4
                            color: parent.accent
                            opacity: parent.agent === null ? 0.28 : 0.9
                        }

                        Column {
                            anchors {
                                left: parent.left
                                right: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 20
                                rightMargin: 12
                            }
                            spacing: 4

                            Text {
                                width: parent.width
                                text: agent === null
                                    ? "SLOT " + (index + 1)
                                    : String(agent.display_name || "Agent")
                                textFormat: Text.PlainText
                                color: agent === null
                                    ? root.theme.textMuted
                                    : root.theme.textPrimary
                                elide: Text.ElideRight
                                font {
                                    family: "monospace"
                                    pixelSize: 13
                                    weight: Font.Bold
                                }
                            }

                            Text {
                                width: parent.width
                                text: agent === null
                                    ? "UNASSIGNED"
                                    : Palette.effectiveAgentState(
                                        agent
                                    ).toUpperCase()
                                textFormat: Text.PlainText
                                color: parent.parent.readableAccent
                                elide: Text.ElideRight
                                font {
                                    family: "monospace"
                                    pixelSize: 10
                                    weight: Font.DemiBold
                                    letterSpacing: 0.6
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
