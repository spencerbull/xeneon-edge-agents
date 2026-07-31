import QtQml
import Quickshell.Io

QtObject {
    id: root

    required property var store
    property bool enabled: true
    property bool previewMode: false
    property string fixturePath: ""

    signal commandEmitted(var command)
    signal commandRejected(string reason)

    property CommandBuilder commandBuilder: CommandBuilder {}

    property Timer restartTimer: Timer {
        interval: 1500
        repeat: false
        onTriggered: {
            if (root.enabled && !root.bridgeProcess.running)
                root.bridgeProcess.running = true
        }
    }

    property Process bridgeProcess: Process {
        command: root.previewMode
            ? ["/usr/bin/tail", "-n", "+1", "-f", root.fixturePath]
            : ["xeneon-agentctl", "qml-bridge"]
        running: root.enabled
        stdinEnabled: !root.previewMode

        stdout: SplitParser {
            onRead: function(line) {
                root.handleLine(line)
            }
        }

        stderr: SplitParser {
            onRead: function(line) {
                root.store.setTransportState(
                    "degraded",
                    String(line || "").trim().slice(0, 120)
                )
            }
        }

        onStarted: {
            root.store.awaitFreshSnapshot(
                root.previewMode ? "fixture" : "streaming",
                root.previewMode
                    ? "Waiting for deterministic fixture snapshot"
                    : "Waiting for a fresh bridge snapshot"
            )
        }

        onExited: function(exitCode, exitStatus) {
            root.store.awaitFreshSnapshot(
                "disconnected",
                "Bridge exited (" + exitCode + ")"
            )
            if (root.enabled)
                root.restartTimer.restart()
        }
    }

    function handleLine(line) {
        var trimmed = String(line || "").trim()
        if (trimmed === "")
            return

        try {
            store.ingestEnvelope(JSON.parse(trimmed))
        } catch (error) {
            store.reject("Invalid NDJSON envelope")
        }
    }

    function sendBuilt(action, agentId, capabilityId, pinnedSequence) {
        if (store.freshSnapshotRequired) {
            commandRejected("Waiting for a fresh snapshot")
            return ""
        }

        var command = commandBuilder.build(
            action,
            agentId,
            capabilityId,
            pinnedSequence
        )
        if (command === null) {
            commandRejected(commandBuilder.lastError)
            return ""
        }

        if (previewMode) {
            store.trackCommand(command)
            commandEmitted(command)
            return command.request_id
        }

        if (!bridgeProcess.running) {
            commandRejected("Bridge is disconnected")
            return ""
        }

        store.trackCommand(command)
        bridgeProcess.write(JSON.stringify(command) + "\n")
        commandEmitted(command)
        return command.request_id
    }

    function openAgent(agentId) {
        return sendBuilt("open", agentId, "", store.sequence)
    }

    function zoomAgent(agentId) {
        return sendBuilt("zoom", agentId, "", store.sequence)
    }

    function approveAgent(agentId, capabilityId, pinnedSequence) {
        return sendBuilt(
            "approve",
            agentId,
            capabilityId,
            pinnedSequence
        )
    }

    function interruptAgent(agentId, capabilityId, pinnedSequence) {
        return sendBuilt(
            "interrupt",
            agentId,
            capabilityId,
            pinnedSequence
        )
    }

    function restoreFocus(pinnedSequence) {
        var sequence = pinnedSequence === undefined
            ? store.sequence
            : pinnedSequence
        return sendBuilt("restore_focus", "", "", sequence)
    }

    function openChatGptDesktop() {
        return sendBuilt("chatgpt_desktop", "", "", store.sequence)
    }

    function openClaudeDesktop() {
        return sendBuilt("claude_desktop", "", "", store.sequence)
    }

    function startVoice() {
        return sendBuilt("voice_start", "", "", store.sequence)
    }

    function stopVoice() {
        return sendBuilt("voice_stop", "", "", store.sequence)
    }

    function cancelVoice() {
        return sendBuilt("voice_cancel", "", "", store.sequence)
    }
}
