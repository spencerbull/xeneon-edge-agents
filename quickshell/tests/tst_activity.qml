import QtQuick
import QtTest
import "../state"

TestCase {
    id: testCase

    name: "ActivityController"

    property double eventNow: 1000

    ActivityController {
        id: activity
        automatic: false
    }

    PortalStore {
        id: store
    }

    Connections {
        target: store

        function onSemanticActivityChanged(signature) {
            activity.noteEvent(testCase.eventNow)
        }
    }

    function init() {
        activity.reset(1000)
        store.reset()
        eventNow = 1000
    }

    function test_entersAmbientAfterSixtySeconds() {
        verify(!activity.evaluate(60999))
        verify(activity.evaluate(61000))
    }

    function test_eventWakesAmbientForFifteenSeconds() {
        verify(activity.evaluate(61000))
        activity.noteEvent(62000)
        verify(!activity.ambientMode)
        verify(!activity.evaluate(76999))
        verify(activity.evaluate(77000))
    }

    function test_touchResetsFullInactivityWindow() {
        verify(activity.evaluate(61000))
        activity.noteUserActivity(62000)
        verify(!activity.ambientMode)
        verify(!activity.evaluate(121999))
        verify(activity.evaluate(122000))
    }

    function metric(value, unit) {
        return {
            "available": true,
            "value": value,
            "unit": unit
        }
    }

    function snapshot(sequence, generatedAtMs, status) {
        return {
            "schema_version": 1,
            "type": "snapshot",
            "sequence": sequence,
            "daemon_epoch": "activity-epoch",
            "generated_at_ms": generatedAtMs,
            "connection": "connected",
            "sessions": [],
            "agents": [{
                "id": "activity-agent",
                "display_name": "Activity Agent",
                "agent": "fixture",
                "status": status,
                "workspace": "fixture",
                "session": "fixture",
                "focused": false,
                "observed_for_seconds": 10,
                "source_order": 0,
                "actions": {
                    "open": true,
                    "zoom": true,
                    "approve": null,
                    "interrupt": null
                }
            }],
            "health": {
                "cpu": metric(10, "%"),
                "cpu_temperature": metric(45, "°C"),
                "gpu": metric(5, "%"),
                "gpu_temperature": metric(43, "°C"),
                "memory": metric(30, "%"),
                "network_down": metric(1000, "B/s"),
                "network_up": metric(500, "B/s"),
                "battery": metric(90, "%")
            }
        }
    }

    function test_periodicSnapshotsPermitAmbientButStatusChangeWakes() {
        verify(store.ingestEnvelope(snapshot(1, 1000, "working")))

        eventNow = 61000
        verify(store.ingestEnvelope(snapshot(2, 61000, "working")))
        verify(activity.evaluate(61000))

        eventNow = 62000
        verify(store.ingestEnvelope(snapshot(3, 62000, "blocked")))
        verify(!activity.ambientMode)
        compare(activity.eventWakeUntilMs, 77000)
        verify(activity.evaluate(77000))
    }
}
