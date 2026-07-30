import QtQml

QtObject {
    id: root

    readonly property var allowedActions: [
        "open",
        "zoom",
        "approve",
        "interrupt",
        "restore_focus"
    ]

    property double snapshotSequence: 0
    property int requestCounter: 0
    property string lastError: ""

    function reset() {
        snapshotSequence = 0
        requestCounter = 0
        lastError = ""
    }

    function build(action, agentId, capabilityId) {
        lastError = ""

        if (allowedActions.indexOf(action) === -1) {
            lastError = "Action is not allowlisted"
            return null
        }

        var normalizedAgentId = String(agentId || "")
        var normalizedCapabilityId = String(capabilityId || "")

        if (action === "restore_focus") {
            if (normalizedAgentId !== ""
                    || normalizedCapabilityId !== "") {
                lastError = "restore_focus cannot target an agent or capability"
                return null
            }
        } else if (normalizedAgentId === "") {
            lastError = "Agent action requires an agent_id"
            return null
        }

        if ((action === "approve" || action === "interrupt")
                && normalizedCapabilityId === "") {
            lastError = "Guarded action requires a capability_id"
            return null
        }

        if ((action === "open" || action === "zoom")
                && normalizedCapabilityId !== "") {
            lastError = "Direct action cannot include a capability_id"
            return null
        }

        requestCounter += 1
        var command = {
            "schema_version": 1,
            "type": "command",
            "request_id": "xep-" + Date.now() + "-" + requestCounter,
            "sequence": Math.max(0, Math.floor(snapshotSequence)),
            "action": action
        }

        if (normalizedAgentId !== "")
            command.agent_id = normalizedAgentId

        if (normalizedCapabilityId !== "")
            command.capability_id = normalizedCapabilityId

        return command
    }
}
