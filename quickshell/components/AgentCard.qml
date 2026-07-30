import QtQuick

Item {
    id: root

    property var agent: null
    property bool reducedMotion: false

    signal openRequested(string agentId)
    signal zoomRequested(string agentId)
    signal approveRequested(string agentId, string capabilityId)
    signal interruptRequested(string agentId, string capabilityId)
    signal interacted()

    readonly property string agentState:
        agent === null ? "unknown" : String(agent.status || "unknown")
    readonly property color accent: stateColor(agentState)

    function stateColor(state) {
        switch (state) {
        case "blocked":
            return "#ff9d52"
        case "done":
            return "#b98cff"
        case "working":
            return "#4fe9ff"
        case "idle":
            return "#6cf7b0"
        default:
            return "#7fa1c6"
        }
    }

    function stateLabel(state) {
        switch (state) {
        case "working":
            return "IN FLIGHT"
        case "blocked":
            return "BLOCKED"
        case "done":
            return "DONE"
        case "idle":
            return "READY"
        default:
            return "UNKNOWN"
        }
    }

    function canAction(action) {
        if (agent === null || agent.actions === null
                || agent.actions === undefined)
            return false
        if (action === "open" || action === "zoom")
            return agent.actions[action] === true
        return agent.actions[action] !== null
                && agent.actions[action] !== undefined
    }

    function capability(action) {
        if (!canAction(action) || action === "open" || action === "zoom")
            return null
        return agent.actions[action]
    }

    function capabilityId(action) {
        var record = capability(action)
        return record === null ? "" : String(record.capability_id || "")
    }

    function observedDuration(seconds) {
        var elapsed = Math.max(0, Number(seconds || 0))
        if (elapsed >= 3600)
            return Math.floor(elapsed / 3600) + "H "
                    + Math.floor((elapsed % 3600) / 60) + "M"
        if (elapsed >= 60)
            return Math.floor(elapsed / 60) + "M"
        return Math.floor(elapsed) + "S"
    }

    function statusSummary() {
        if (agent === null)
            return ""
        var location = String(agent.session || "Herdr")
        var duration = observedDuration(agent.observed_for_seconds)
        if (agent.focused)
            return "Focused in " + location + " · observed " + duration
        switch (agentState) {
        case "blocked":
            return "Waiting for interaction in " + location
        case "done":
            return "Completed activity observed " + duration + " ago"
        case "working":
            return "Active in " + location + " · observed " + duration
        case "idle":
            return "Ready in " + location + " · observed " + duration
        default:
            return "State unavailable · " + location
        }
    }

    scale: openHandler.pressed ? 0.988 : 1
    opacity: agent === null ? 0 : 1

    Behavior on scale {
        NumberAnimation {
            duration: root.reducedMotion ? 0 : 110
            easing.type: Easing.OutCubic
        }
    }

    Accessible.role: Accessible.Button
    Accessible.name: agent === null
        ? ""
        : String(agent.display_name || "Agent")
    Accessible.description: agent === null
        ? ""
        : stateLabel(agentState) + ". " + statusSummary()

    Rectangle {
        id: cardSurface

        anchors.fill: parent
        radius: 18
        color: "#0a101d"
        border.width: 1
        border.color: Qt.alpha(root.accent, 0.64)
    }

    Rectangle {
        anchors {
            fill: parent
            margins: 4
        }
        radius: 15
        color: "transparent"
        border.width: 1
        border.color: Qt.alpha(root.accent, 0.13)
    }

    Rectangle {
        id: pulseGlow

        anchors {
            left: parent.left
            top: parent.top
            bottom: parent.bottom
        }
        width: 6
        radius: 3
        color: root.accent
        opacity: 0.82

        SequentialAnimation on opacity {
            loops: Animation.Infinite
            running: !root.reducedMotion
                && root.agentState === "working"
            NumberAnimation {
                from: 0.42
                to: 1
                duration: 900
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                from: 1
                to: 0.42
                duration: 900
                easing.type: Easing.InOutSine
            }
        }
    }

    Item {
        id: openZone

        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            bottom: actionRow.top
            leftMargin: 22
            rightMargin: 18
            topMargin: 16
            bottomMargin: 8
        }

        Row {
            id: titleRow

            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
            }
            height: 36
            spacing: 12

            Rectangle {
                width: 12
                height: 12
                radius: 6
                anchors.verticalCenter: parent.verticalCenter
                color: root.accent
            }

            Text {
                width: titleRow.width - statePill.width - 36
                anchors.verticalCenter: parent.verticalCenter
                text: root.agent === null
                    ? ""
                    : String(root.agent.display_name || "")
                color: "#f3fbff"
                elide: Text.ElideRight
                font {
                    family: "monospace"
                    pixelSize: 23
                    weight: Font.Bold
                }
            }

            Rectangle {
                id: statePill

                width: stateText.implicitWidth + 24
                height: 28
                radius: 14
                anchors.verticalCenter: parent.verticalCenter
                color: Qt.alpha(root.accent, 0.14)
                border.width: 1
                border.color: Qt.alpha(root.accent, 0.62)

                Text {
                    id: stateText

                    anchors.centerIn: parent
                    text: root.stateLabel(root.agentState)
                    color: root.accent
                    font {
                        family: "monospace"
                        pixelSize: 12
                        weight: Font.DemiBold
                        letterSpacing: 0.8
                    }
                }
            }
        }

        Text {
            id: summaryText

            anchors {
                left: parent.left
                right: parent.right
                top: titleRow.bottom
                topMargin: 12
            }
            height: 52
            text: root.agent === null
                ? ""
                : root.statusSummary()
            color: "#b8cce2"
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            font {
                family: "sans-serif"
                pixelSize: 18
                weight: Font.Medium
            }
        }

        Row {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            height: 24
            spacing: 18

            Text {
                width: parent.width * 0.31
                text: root.agent === null
                    ? ""
                    : String(root.agent.agent || "Agent").toUpperCase()
                color: "#6f8aa7"
                elide: Text.ElideRight
                font {
                    family: "monospace"
                    pixelSize: 13
                    letterSpacing: 0.6
                }
            }

            Text {
                width: parent.width * 0.35
                text: root.agent === null
                    ? ""
                    : String(root.agent.workspace || "LOCAL")
                color: "#6f8aa7"
                elide: Text.ElideMiddle
                horizontalAlignment: Text.AlignHCenter
                font {
                    family: "monospace"
                    pixelSize: 13
                }
            }

            Text {
                width: parent.width * 0.27
                text: root.agent === null
                    ? ""
                    : String(root.agent.session || "HERDR")
                color: "#6f8aa7"
                elide: Text.ElideLeft
                horizontalAlignment: Text.AlignRight
                font {
                    family: "monospace"
                    pixelSize: 13
                }
            }
        }

        TapHandler {
            id: openHandler

            enabled: root.agent !== null && root.canAction("open")
            gesturePolicy: TapHandler.DragThreshold
            onTapped: {
                root.interacted()
                root.openRequested(String(root.agent.id))
            }
        }
    }

    Row {
        id: actionRow

        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
            margins: 12
            leftMargin: 20
        }
        height: 48
        spacing: 8

        Rectangle {
            id: zoomButton

            width: 88
            height: parent.height
            radius: 10
            color: zoomHandler.pressed ? "#172c42" : "#0d1827"
            border.width: 1
            border.color: "#335775"
            opacity: root.canAction("zoom") ? 1 : 0.35

            Accessible.role: Accessible.Button
            Accessible.name: "Zoom agent pane"

            Text {
                anchors.centerIn: parent
                text: "ZOOM"
                color: "#9bdcff"
                font {
                    family: "monospace"
                    pixelSize: 14
                    weight: Font.DemiBold
                    letterSpacing: 0.8
                }
            }

            TapHandler {
                id: zoomHandler

                enabled: root.agent !== null && root.canAction("zoom")
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: {
                    root.interacted()
                    root.zoomRequested(String(root.agent.id))
                }
            }
        }

        HoldControl {
            width: root.capability("approve") !== null
                    && root.capability("interrupt") !== null
                ? (actionRow.width - 112) / 2
                : actionRow.width - 104
            height: parent.height
            visible: root.capability("approve") !== null
            enabled: visible
            label: "HOLD APPROVE"
            accent: "#6cf7b0"
            reducedMotion: root.reducedMotion
            onInteracted: root.interacted()
            onConfirmed: root.approveRequested(
                String(root.agent.id),
                root.capabilityId("approve")
            )
        }

        HoldControl {
            width: root.capability("approve") !== null
                    && root.capability("interrupt") !== null
                ? (actionRow.width - 112) / 2
                : actionRow.width - 104
            height: parent.height
            visible: root.capability("interrupt") !== null
            enabled: visible
            label: "HOLD INTERRUPT"
            accent: "#ff5d83"
            reducedMotion: root.reducedMotion
            onInteracted: root.interacted()
            onConfirmed: root.interruptRequested(
                String(root.agent.id),
                root.capabilityId("interrupt")
            )
        }
    }
}
