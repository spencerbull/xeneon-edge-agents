import QtQuick
import "PortalPalette.js" as Palette

Item {
    id: root

    property bool opened: false
    property bool reducedMotion: false
    property bool interactive: true
    property var micro: ({"connected": false})
    property var agents: []
    property var voice: ({"state": "unavailable", "owned": false})

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
            return "#49e0cf"
        case "processing":
            return "#eefcff"
        case "error":
            return "#ff435f"
        case "blocked":
            return "#ffad3d"
        case "review":
            return "#5df09a"
        case "working":
            return "#4d9dff"
        default:
            return "#30465b"
        }
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
        color: "#9c02050b"

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
        color: "#f20a111d"
        border.width: 1
        border.color: root.micro.connected ? "#3d7891" : "#5c3543"

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
                color: "#ecfbff"
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
                color: root.micro.connected ? "#62e5c2" : "#ff6d86"
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
            color: closeTap.pressed ? "#1b3043" : "#101d2c"
            border.width: 1
            border.color: "#35536c"

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
                color: "#9ec7df"
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
                    color: "#06101a"
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
                            color: "#f0fbff"
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
                            color: root.ringColor()
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
                    color: "#718da5"
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
                            agent === null ? "#293b4c" : Palette.agentColor(agent)

                        width: (slotGrid.width - slotGrid.columnSpacing) / 2
                        height: (slotGrid.height - slotGrid.rowSpacing * 2) / 3
                        radius: 15
                        color: "#0b1724"
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
                                color: agent === null ? "#526779" : "#e8f7fc"
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
                                color: parent.parent.accent
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
