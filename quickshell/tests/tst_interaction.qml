import QtQuick
import QtTest
import "../components"

TestCase {
    id: testCase

    name: "PortalInteraction"
    width: 900
    height: 360

    HoldControl {
        id: hold

        width: 240
        height: 48
        targetAgentId: "agent-a"
        targetCapabilityId: "capability-a"
        targetSequence: 7
    }

    SignalSpy {
        id: confirmedSpy
        target: hold
        signalName: "confirmed"
    }

    SignalSpy {
        id: cancelledSpy
        target: hold
        signalName: "cancelled"
    }

    SignalSpy {
        id: accessibleHoldSpy
        target: hold
        signalName: "accessibleHoldRequested"
    }

    AgentCard {
        id: hostileCard

        x: 280
        width: 580
        height: 300
        snapshotSequence: 7
        agent: ({
            "id": "hostile-agent",
            "display_name": "<img src=\"https://example.invalid/tracker\">",
            "agent": "fixture",
            "status": "working",
            "workspace": "<b>workspace</b>",
            "session": "fixture",
            "focused": false,
            "observed_for_seconds": 1,
            "actions": {
                "open": true,
                "zoom": true,
                "approve": null,
                "interrupt": null
            }
        })
    }

    function init() {
        hold.finishHold()
        hold.targetAgentId = "agent-a"
        hold.targetCapabilityId = "capability-a"
        hold.targetSequence = 7
        confirmedSpy.clear()
        cancelledSpy.clear()
        accessibleHoldSpy.clear()
    }

    function test_guardedHoldEmitsPinnedIdentityAndSequence() {
        verify(hold.beginHold())
        verify(hold.confirmHold())
        compare(confirmedSpy.count, 1)
        compare(confirmedSpy.signalArguments[0][0], "agent-a")
        compare(confirmedSpy.signalArguments[0][1], "capability-a")
        compare(confirmedSpy.signalArguments[0][2], 7)
    }

    function test_guardedHoldCancelsSlotRetargeting() {
        verify(hold.beginHold())
        hold.targetAgentId = "agent-b"
        compare(cancelledSpy.count, 1)
        verify(!hold.armed)
        verify(!hold.confirmHold())
        compare(confirmedSpy.count, 0)
    }

    function test_guardedHoldCancelsCapabilityOrSequenceChange() {
        verify(hold.beginHold())
        hold.targetCapabilityId = "capability-b"
        compare(cancelledSpy.count, 1)
        verify(!hold.confirmHold())

        init()
        verify(hold.beginHold())
        hold.targetSequence = 8
        compare(cancelledSpy.count, 1)
        verify(!hold.confirmHold())
        compare(confirmedSpy.count, 0)
    }

    function test_equalSequenceHealthRefreshDoesNotCancelHold() {
        verify(hold.beginHold())
        hold.targetSequence = 7
        compare(cancelledSpy.count, 0)
        verify(hold.armed)
        verify(hold.confirmHold())
        compare(confirmedSpy.count, 1)
    }

    function test_accessiblePressCannotBypassHold() {
        hold.accessibleHoldRequested()
        compare(accessibleHoldSpy.count, 1)
        compare(confirmedSpy.count, 0)
        verify(!hold.armed)
    }

    function test_hostileImageMarkupRemainsPlainText() {
        var displayName = findChild(hostileCard, "agentDisplayName")
        verify(displayName !== null)
        compare(
            displayName.text,
            "<img src=\"https://example.invalid/tracker\">"
        )
        compare(displayName.textFormat, Text.PlainText)
    }
}
