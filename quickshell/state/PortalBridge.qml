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

    property CommandBuilder commandBuilder: CommandBuilder {
        snapshotSequence: Math.max(0, Number(root.store.sequence))
    }

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
            root.store.setTransportState(
                root.previewMode ? "fixture" : "streaming",
                root.previewMode ? "Deterministic fixture stream" : ""
            )
        }

        onExited: function(exitCode, exitStatus) {
            root.store.setTransportState(
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

    function sendBuilt(action, agentId, capabilityId) {
        var command = commandBuilder.build(action, agentId, capabilityId)
        if (command === null) {
            commandRejected(commandBuilder.lastError)
            return false
        }

        if (previewMode) {
            commandEmitted(command)
            return true
        }

        if (!bridgeProcess.running) {
            commandRejected("Bridge is disconnected")
            return false
        }

        bridgeProcess.write(JSON.stringify(command) + "\n")
        commandEmitted(command)
        return true
    }

    function openAgent(agentId) {
        return sendBuilt("open", agentId, "")
    }

    function zoomAgent(agentId) {
        return sendBuilt("zoom", agentId, "")
    }

    function approveAgent(agentId, capabilityId) {
        return sendBuilt("approve", agentId, capabilityId)
    }

    function interruptAgent(agentId, capabilityId) {
        return sendBuilt("interrupt", agentId, capabilityId)
    }

    function restoreFocus() {
        return sendBuilt("restore_focus", "", "")
    }
}
