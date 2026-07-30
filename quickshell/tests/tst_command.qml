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
    }

    function test_buildsOnlyCommandEnvelope() {
        var command = builder.build("open", "agent-1", "", 42)
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
        compare(builder.build("approve", "agent-1", "", 42), null)
        compare(builder.lastError, "Guarded action requires a capability_id")

        var approve = builder.build(
            "approve",
            "agent-1",
            "capability-approve",
            42
        )
        verify(approve !== null)
        compare(approve.capability_id, "capability-approve")

        compare(
            builder.build("interrupt", "", "capability-stop", 42),
            null
        )
        compare(builder.lastError, "Agent action requires an agent_id")
    }

    function test_restoreFocusCannotTargetAgent() {
        var restore = builder.build("restore_focus", "", "", 42)
        verify(restore !== null)
        compare(restore.agent_id, undefined)
        compare(restore.capability_id, undefined)

        compare(builder.build("restore_focus", "agent-1", "", 42), null)
        compare(
            builder.lastError,
            "restore_focus cannot target an agent or capability"
        )

        compare(
            builder.build("restore_focus", "", "stale-capability", 42),
            null
        )
    }

    function test_rejectsRawOrUnknownActions() {
        compare(builder.build("send_keys", "agent-1", "", 42), null)
        compare(builder.build("shell", "agent-1", "", 42), null)
        compare(builder.build("", "agent-1", "", 42), null)
        compare(builder.requestCounter, 0)
    }

    function test_sequenceIsExplicitlyPinnedPerCommand() {
        compare(builder.build("open", "agent-1", "", 42).sequence, 42)
        compare(builder.build("zoom", "agent-1", "", 42).sequence, 42)
        compare(builder.build("restore_focus", "", "", 43).sequence, 43)
        compare(builder.requestCounter, 3)
    }

    function test_rejectsMissingOrInvalidPinnedSequence() {
        compare(builder.build("open", "agent-1", "", undefined), null)
        compare(
            builder.lastError,
            "Command requires a valid snapshot sequence"
        )
        compare(builder.build("open", "agent-1", "", -1), null)
        compare(builder.build("open", "agent-1", "", "not-a-number"), null)
        compare(builder.requestCounter, 0)
    }

    function test_directActionsRejectCapabilities() {
        compare(
            builder.build("open", "agent-1", "stale-capability", 42),
            null
        )
        compare(
            builder.lastError,
            "Direct action cannot include a capability_id"
        )
    }
}
