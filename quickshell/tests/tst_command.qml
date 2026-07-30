import QtQuick
import QtTest
import "../state"

TestCase {
    id: testCase

    name: "CommandBuilder"

    CommandBuilder {
        id: builder
    }

    function init() {
        builder.reset()
        builder.snapshotSequence = 42
    }

    function test_buildsOnlyCommandEnvelope() {
        var command = builder.build("open", "agent-1", "")
        verify(command !== null)
        compare(command.schema_version, 1)
        compare(command.type, "command")
        compare(command.action, "open")
        compare(command.agent_id, "agent-1")
        compare(command.sequence, 42)
        compare(command.capability_id, undefined)
        compare(command.keys, undefined)
        compare(command.text, undefined)
    }

    function test_guardedActionsRequireCapabilities() {
        compare(builder.build("approve", "agent-1", ""), null)
        compare(builder.lastError, "Guarded action requires a capability_id")

        var approve = builder.build(
            "approve",
            "agent-1",
            "capability-approve"
        )
        verify(approve !== null)
        compare(approve.capability_id, "capability-approve")

        compare(builder.build("interrupt", "", "capability-stop"), null)
        compare(builder.lastError, "Agent action requires an agent_id")
    }

    function test_restoreFocusCannotTargetAgent() {
        var restore = builder.build("restore_focus", "", "")
        verify(restore !== null)
        compare(restore.agent_id, undefined)
        compare(restore.capability_id, undefined)

        compare(builder.build("restore_focus", "agent-1", ""), null)
        compare(
            builder.lastError,
            "restore_focus cannot target an agent or capability"
        )

        compare(
            builder.build("restore_focus", "", "stale-capability"),
            null
        )
    }

    function test_rejectsRawOrUnknownActions() {
        compare(builder.build("send_keys", "agent-1", ""), null)
        compare(builder.build("shell", "agent-1", ""), null)
        compare(builder.build("", "agent-1", ""), null)
        compare(builder.requestCounter, 0)
    }

    function test_sequenceStaysPinnedToCurrentSnapshot() {
        compare(builder.build("open", "agent-1", "").sequence, 42)
        compare(builder.build("zoom", "agent-1", "").sequence, 42)
        builder.snapshotSequence = 43
        compare(builder.build("restore_focus", "", "").sequence, 43)
        compare(builder.requestCounter, 3)
    }

    function test_directActionsRejectCapabilities() {
        compare(builder.build("open", "agent-1", "stale-capability"), null)
        compare(
            builder.lastError,
            "Direct action cannot include a capability_id"
        )
    }
}
