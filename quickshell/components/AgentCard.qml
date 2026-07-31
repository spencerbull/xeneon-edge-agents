import QtQuick
import "PortalPalette.js" as Palette

Item {
    id: root

    property var agent: null
    property bool reducedMotion: false
    property double snapshotSequence: -1
    property bool actionsEnabled: true

    signal focusRequested(string agentId)
    signal approveRequested(
        string agentId,
        string capabilityId,
        double sequence
    )
    signal interruptRequested(
        string agentId,
        string capabilityId,
        double sequence
    )
    signal interacted()

    readonly property string agentState: Palette.effectiveAgentState(agent)
    readonly property color accent: Palette.agentColor(agent)
    readonly property color readableAccent:
        agentState === "idle" || agentState === "unknown"
            ? "#a9b7c7"
            : accent
    readonly property bool hasApproveAction:
        capability("approve") !== null
    readonly property bool hasInterruptAction:
        capability("interrupt") !== null
    readonly property bool hasGuardedActions:
        hasApproveAction || hasInterruptAction

    function stateLabel(state) {
        if (agent !== null && agent.launch_pending === true)
            return "LAUNCHING"
        switch (state) {
        case "working":
            return "WORKING"
        case "blocked":
            return "WAITING"
        case "review":
            return "REVIEW READY"
        case "idle":
            return "READY"
        default:
            return "UNKNOWN"
        }
    }

    function canAction(action) {
        if (!actionsEnabled || agent === null || agent.actions === null
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

    function processLine() {
        if (agent === null)
            return ""
        return stateLabel(agentState) + "  ·  "
            + observedDuration(agent.observed_for_seconds) + " IN STATE"
    }

    function contextLine() {
        if (agent === null)
            return ""
        var context = []
        var repository = String(agent.repository || "").trim()
        var worktree = String(agent.worktree || "").trim()
        var workspace = String(agent.workspace || "").trim()
        if (repository !== "")
            context.push(repository)
        if (worktree !== "" && worktree !== repository)
            context.push(worktree)
        if (workspace !== ""
                && workspace !== repository
                && (repository === "" || workspace.indexOf(repository) < 0))
            context.push(workspace)
        return context.length > 0 ? context.join("  ·  ") : "LOCAL WORKSPACE"
    }

    function requestFocus() {
        if (!root.enabled || agent === null || !canAction("open"))
            return false
        interacted()
        focusRequested(String(agent.id))
        return true
    }

    opacity: agent === null ? 0 : 1

    Accessible.role: Accessible.Button
    Accessible.ignored: !root.enabled || root.agent === null
    Accessible.name: agent === null
        ? ""
        : "Focus " + String(agent.display_name || "Agent") + " in Herdr"
    Accessible.description: agent === null
        ? ""
        : processLine() + ". " + contextLine() + ". Tap to focus in Herdr."
    Accessible.onPressAction: root.requestFocus()

    MouseArea {
        id: focusHandler

        objectName: "wholeCardFocusTarget"
        anchors.fill: parent
        z: 10
        enabled: root.agent !== null
            && root.canAction("open")
            && !root.hasGuardedActions
        onClicked: root.requestFocus()
    }

    Rectangle {
        anchors.fill: parent
        radius: 18
        color: focusHandler.pressed || guardedFocusHandler.pressed
            ? "#0d1726"
            : "#0a101d"
        border.width: root.agent !== null && root.agent.focused ? 2 : 1
        border.color: Qt.alpha(
            root.accent,
            root.agent !== null && root.agent.focused ? 0.95 : 0.58
        )
    }

    Rectangle {
        anchors {
            fill: parent
            margins: 4
        }
        radius: 15
        color: "transparent"
        border.width: 1
        border.color: Qt.alpha(root.accent, 0.12)
    }

    Rectangle {
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
                && (root.agentState === "working"
                    || root.agentState === "blocked")
            NumberAnimation {
                from: 0.42
                to: 1
                duration: root.agentState === "blocked" ? 520 : 900
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                from: 1
                to: 0.42
                duration: root.agentState === "blocked" ? 520 : 900
                easing.type: Easing.InOutSine
            }
        }
    }

    Rectangle {
        id: activitySweep

        visible: !root.reducedMotion && root.agentState === "working"
        width: Math.min(190, root.width * 0.28)
        height: 2
        radius: 1
        y: 3
        color: root.accent
        opacity: 0.78

        SequentialAnimation on x {
            loops: Animation.Infinite
            running: activitySweep.visible
            NumberAnimation {
                from: 14
                to: Math.max(14, root.width - activitySweep.width - 14)
                duration: 1450
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                from: Math.max(14, root.width - activitySweep.width - 14)
                to: 14
                duration: 1450
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
            bottom: root.hasGuardedActions ? actionRow.top : parent.bottom
            leftMargin: 22
            rightMargin: 18
            topMargin: 14
            bottomMargin: root.hasGuardedActions ? 8 : 18
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
                objectName: "agentDisplayName"
                width: titleRow.width - statePill.width - 36
                anchors.verticalCenter: parent.verticalCenter
                text: root.agent === null
                    ? ""
                    : String(root.agent.display_name || "")
                textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
                    color: root.readableAccent
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
            anchors {
                left: parent.left
                right: parent.right
                top: titleRow.bottom
                topMargin: 9
            }
            text: root.processLine()
            textFormat: Text.PlainText
            color: root.readableAccent
            elide: Text.ElideRight
            font {
                family: "monospace"
                pixelSize: 17
                weight: Font.DemiBold
                letterSpacing: 0.7
            }
        }

        Text {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            text: root.contextLine()
            textFormat: Text.PlainText
            color: "#7894ae"
            elide: Text.ElideMiddle
            font {
                family: "monospace"
                pixelSize: 13
                letterSpacing: 0.3
            }
        }

        MouseArea {
            id: guardedFocusHandler

            anchors.fill: parent
            z: 10
            enabled: root.agent !== null
                && root.canAction("open")
                && root.hasGuardedActions
            onClicked: root.requestFocus()
        }

    }

    Row {
        id: actionRow

        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
            leftMargin: 20
            rightMargin: 14
            bottomMargin: 12
        }
        height: 46
        spacing: 8
        visible: root.hasGuardedActions

        HoldControl {
            width: root.hasApproveAction && root.hasInterruptAction
                ? (actionRow.width - actionRow.spacing) / 2
                : actionRow.width
            height: parent.height
            visible: root.hasApproveAction
            enabled: visible
            label: "HOLD APPROVE"
            accent: "#6cf7b0"
            reducedMotion: root.reducedMotion
            targetAgentId: root.agent === null ? "" : String(root.agent.id)
            targetCapabilityId: root.capabilityId("approve")
            targetSequence: root.snapshotSequence
            onInteracted: root.interacted()
            onConfirmed: function(agentId, capabilityId, sequence) {
                root.approveRequested(agentId, capabilityId, sequence)
            }
        }

        HoldControl {
            width: root.hasApproveAction && root.hasInterruptAction
                ? (actionRow.width - actionRow.spacing) / 2
                : actionRow.width
            height: parent.height
            visible: root.hasInterruptAction
            enabled: visible
            label: "HOLD INTERRUPT"
            accent: "#ff5d83"
            reducedMotion: root.reducedMotion
            targetAgentId: root.agent === null ? "" : String(root.agent.id)
            targetCapabilityId: root.capabilityId("interrupt")
            targetSequence: root.snapshotSequence
            onInteracted: root.interacted()
            onConfirmed: function(agentId, capabilityId, sequence) {
                root.interruptRequested(agentId, capabilityId, sequence)
            }
        }
    }
}
