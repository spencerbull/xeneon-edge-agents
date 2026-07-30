import QtQuick
import QtTest
import "../state"

TestCase {
    id: testCase

    name: "PortalStore"

    PortalStore {
        id: store
    }

    SignalSpy {
        id: semanticActivitySpy
        target: store
        signalName: "semanticActivityChanged"
    }

    function init() {
        store.reset()
        semanticActivitySpy.clear()
    }

    function metric(value, unit) {
        return {
            "available": value !== null,
            "value": value,
            "unit": unit
        }
    }

    function health() {
        return {
            "cpu": metric(12, "%"),
            "cpu_temperature": metric(47, "°C"),
            "gpu": metric(9, "%"),
            "gpu_temperature": metric(null, "°C"),
            "memory": metric(40, "%"),
            "network_down": metric(1000, "B/s"),
            "network_up": metric(2000, "B/s"),
            "battery": metric(80, "%")
        }
    }

    function snapshot(sequence, epoch, agents, connectionState) {
        return {
            "schema_version": 1,
            "type": "snapshot",
            "sequence": sequence,
            "daemon_epoch": epoch,
            "generated_at_ms": 1000 + sequence,
            "connection": connectionState || "connected",
            "sessions": [{
                "name": "fixture",
                "state": "connected",
                "version": "1.0",
                "protocol": 1,
                "last_sync_ms": 900 + sequence
            }],
            "agents": agents,
            "health": health()
        }
    }

    function agent(id, sourceOrder, status) {
        return {
            "id": id,
            "display_name": "Agent " + id,
            "agent": "fixture",
            "status": status,
            "workspace": "fixture-workspace",
            "repository": "fixture/repository",
            "worktree": "fixture-worktree",
            "session": "fixture",
            "focused": false,
            "observed_for_seconds": 3,
            "source_order": sourceOrder,
            "terminal_text": "must be discarded",
            "prompt_text": "must be discarded",
            "actions": {
                "open": true,
                "zoom": true,
                "approve": sourceOrder === 0
                    ? {
                        "capability_id": "approve-" + id,
                        "kind": "approve",
                        "expires_at_ms": 9000,
                        "expected_revision": 2
                    }
                    : null,
                "interrupt": null
            }
        }
    }

    function test_acceptsFullSnapshotAndSortsAttention() {
        var accepted = store.ingestEnvelope(snapshot(
            10,
            "epoch-a",
            [
                agent("later", 5, "working"),
                agent("first", 0, "blocked"),
                agent("middle", 2, "done")
            ]
        ))

        verify(accepted)
        verify(store.hasSnapshot)
        compare(store.sequence, 10)
        compare(store.daemonEpoch, "epoch-a")
        compare(store.agents.length, 3)
        compare(store.agents[0].id, "first")
        compare(store.agents[1].id, "middle")
        compare(store.agents[2].id, "later")
        compare(store.agents[0].actions.approve.capability_id, "approve-first")
        compare(store.agents[0].actions.open, true)
        compare(store.agents[0].terminal_text, undefined)
        compare(store.agents[0].prompt_text, undefined)
        compare(store.connection.state, "connected")
        compare(store.health.gpu_temperature.available, false)
        compare(store.health.gpu_temperature.value, null)
        compare(store.health.status, "partial")
        compare(store.surfaceState(), "ready")
    }

    function test_rejectsStaleSequenceButAcceptsNewEpoch() {
        verify(store.ingestEnvelope(snapshot(
            10,
            "epoch-a",
            [agent("old", 0, "working")]
        )))
        verify(!store.ingestEnvelope(snapshot(
            9,
            "epoch-a",
            [agent("stale", 0, "blocked")]
        )))
        compare(store.agents[0].id, "old")

        verify(store.ingestEnvelope(snapshot(
            1,
            "epoch-b",
            [agent("new", 0, "idle")]
        )))
        compare(store.sequence, 1)
        compare(store.daemonEpoch, "epoch-b")
        compare(store.agents[0].id, "new")
    }

    function test_equalSequenceAcceptsOnlyNewerHealthSnapshot() {
        var initial = snapshot(
            10,
            "epoch-health",
            [agent("health-agent", 0, "working")]
        )
        initial.generated_at_ms = 2000
        verify(store.ingestEnvelope(initial))
        compare(semanticActivitySpy.count, 0)

        var refresh = snapshot(
            10,
            "epoch-health",
            [agent("health-agent", 0, "working")]
        )
        refresh.generated_at_ms = 3000
        refresh.health.cpu.value = 67
        refresh.connection = "offline"
        refresh.sessions = []
        refresh.agents = [agent("retargeted", 0, "blocked")]
        refresh.agents[0].actions.approve.capability_id = "replacement"
        verify(store.ingestEnvelope(refresh))
        compare(store.sequence, 10)
        compare(store.generatedAtMs, 3000)
        compare(store.health.cpu.value, 67)
        compare(store.connection.state, "connected")
        compare(store.sessions.length, 1)
        compare(store.agents.length, 1)
        compare(store.agents[0].id, "health-agent")
        compare(
            store.agents[0].actions.approve.capability_id,
            "approve-health-agent"
        )
        compare(semanticActivitySpy.count, 0)

        verify(!store.ingestEnvelope(refresh))
        refresh.generated_at_ms = 2500
        verify(!store.ingestEnvelope(refresh))
        compare(store.health.cpu.value, 67)
    }

    function test_semanticActivityIgnoresSequenceOnlyChanges() {
        verify(store.ingestEnvelope(snapshot(
            1,
            "epoch-activity",
            [agent("activity-agent", 0, "working")]
        )))
        verify(store.ingestEnvelope(snapshot(
            2,
            "epoch-activity",
            [agent("activity-agent", 0, "working")]
        )))
        compare(semanticActivitySpy.count, 0)

        verify(store.ingestEnvelope(snapshot(
            3,
            "epoch-activity",
            [agent("activity-agent", 0, "blocked")]
        )))
        compare(semanticActivitySpy.count, 1)
    }

    function test_acceptsCapturedAtAlias() {
        var envelope = snapshot(
            3,
            "epoch-alias",
            [agent("alias", 0, "idle")]
        )
        delete envelope.generated_at_ms
        envelope.captured_at_ms = 9876

        verify(store.ingestEnvelope(envelope))
        compare(store.generatedAtMs, 9876)
    }

    function test_requiresFullSnapshotEnvelope() {
        verify(!store.ingestEnvelope({
            "schema_version": 1,
            "type": "agents",
            "sequence": 2,
            "agents": []
        }))
        compare(store.protocolError, "Unsupported envelope type")

        verify(!store.ingestEnvelope({
            "schema_version": 2,
            "type": "snapshot"
        }))
        compare(store.protocolError, "Unsupported schema version")
    }

    function test_capabilityKindMustMatchSlot() {
        var mismatched = agent("mismatch", 0, "blocked")
        mismatched.actions.approve.kind = "interrupt"
        verify(store.ingestEnvelope(snapshot(
            12,
            "epoch-capability",
            [mismatched]
        )))
        compare(store.agents[0].actions.approve, null)
    }

    function test_actionResultAndNoticeAreNormalized() {
        verify(store.trackCommand({
            "request_id": "request-1",
            "action": "approve"
        }))
        verify(store.ingestEnvelope({
            "schema_version": 1,
            "type": "action_result",
            "request_id": "request-1",
            "ok": true,
            "code": "ok",
            "message": "Accepted",
            "raw_output": "discarded"
        }))
        compare(store.lastActionResult.ok, true)
        compare(store.lastActionResult.code, "ok")
        compare(store.lastActionResult.action, "approve")
        compare(store.lastActionResult.raw_output, undefined)

        verify(store.ingestEnvelope({
            "schema_version": 1,
            "type": "notice",
            "level": "warning",
            "code": "session_stale",
            "message": "Session metadata is stale",
            "raw_output": "discarded"
        }))
        compare(store.lastNotice.code, "session_stale")
        compare(store.lastNotice.raw_output, undefined)

        verify(!store.ingestEnvelope({
            "schema_version": 1,
            "type": "action_result",
            "request_id": "missing-result-fields"
        }))
    }

    function test_restoreFocusResultsRemainSeparatelyCorrelated() {
        verify(store.trackCommand({
            "request_id": "guarded-request",
            "action": "interrupt"
        }))
        verify(store.trackCommand({
            "request_id": "restore-request",
            "action": "restore_focus"
        }))
        store.awaitFreshSnapshot("disconnected", "Bridge exited (1)")

        verify(store.ingestEnvelope({
            "schema_version": 1,
            "type": "action_result",
            "request_id": "guarded-request",
            "ok": false,
            "code": "stale_capability",
            "message": "The guarded action failed"
        }))
        compare(store.lastActionResult.action, "interrupt")
        compare(store.lastActionResult.ok, false)

        verify(store.ingestEnvelope({
            "schema_version": 1,
            "type": "action_result",
            "request_id": "restore-request",
            "ok": true,
            "code": "focus_restored",
            "message": "Focus restored"
        }))
        compare(store.lastActionResult.action, "restore_focus")
        compare(store.pendingRequestOrder.length, 0)
    }

    function test_invalidAvailableMetricBecomesUnavailable() {
        var invalid = snapshot(
            20,
            "epoch-invalid-health",
            [agent("health", 0, "working")]
        )
        invalid.health.cpu = {"available": true, "unit": "%"}
        invalid.health.gpu = {
            "available": true,
            "value": "73",
            "unit": "%"
        }

        verify(store.ingestEnvelope(invalid))
        compare(store.health.cpu.available, false)
        compare(store.health.cpu.value, null)
        compare(store.health.gpu.available, false)
        compare(store.health.gpu.value, null)
        compare(store.health.status, "partial")
    }

    function test_reconnectRequiresFreshNonstaleSnapshot() {
        verify(store.ingestEnvelope(snapshot(
            8,
            "epoch-reconnect",
            [agent("before-exit", 0, "working")]
        )))
        compare(store.surfaceState(), "ready")

        store.awaitFreshSnapshot("disconnected", "Bridge exited (1)")
        compare(store.surfaceState(), "disconnected")
        compare(store.sequence, 8)
        compare(store.agents[0].id, "before-exit")

        store.awaitFreshSnapshot("streaming", "Waiting for snapshot")
        compare(store.surfaceState(), "loading")
        verify(!store.ingestEnvelope(snapshot(
            7,
            "epoch-reconnect",
            [agent("stale", 0, "blocked")]
        )))
        compare(store.surfaceState(), "loading")

        verify(store.ingestEnvelope(snapshot(
            8,
            "epoch-reconnect",
            [agent("fresh", 0, "idle")]
        )))
        compare(store.surfaceState(), "ready")
        compare(store.agents[0].id, "before-exit")

        verify(store.ingestEnvelope(snapshot(
            9,
            "epoch-reconnect",
            [agent("fresh", 0, "idle")]
        )))
        compare(store.agents[0].id, "fresh")
    }

    function test_offlineAndEmptyStates() {
        verify(store.ingestEnvelope(snapshot(
            4,
            "epoch-offline",
            [],
            "offline"
        )))
        compare(store.surfaceState(), "disconnected")

        store.reset()
        verify(store.ingestEnvelope(snapshot(
            5,
            "epoch-empty",
            [],
            "connected"
        )))
        compare(store.surfaceState(), "empty")
    }
}
