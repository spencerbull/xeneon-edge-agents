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

    VoiceControl {
        id: voice

        x: 280
        y: 305
        width: 360
        height: 52
        voice: ({
            "available": true,
            "state": "idle",
            "owned": false
        })
    }

    DesktopAppButton {
        id: chatGptButton
        x: 0
        y: 260
        width: 180
        height: 52
        label: "CHATGPT"
    }

    DesktopAppButton {
        id: claudeButton
        x: 0
        y: 312
        width: 180
        height: 48
        label: "CLAUDE"
    }

    SignalSpy {
        id: agentFocusSpy
        target: hostileCard
        signalName: "focusRequested"
    }

    SignalSpy {
        id: chatGptSpy
        target: chatGptButton
        signalName: "triggered"
    }

    SignalSpy {
        id: claudeSpy
        target: claudeButton
        signalName: "triggered"
    }

    SignalSpy {
        id: voiceStartSpy
        target: voice
        signalName: "startRequested"
    }

    SignalSpy {
        id: voiceStopSpy
        target: voice
        signalName: "stopRequested"
    }

    SignalSpy {
        id: voiceCancelSpy
        target: voice
        signalName: "cancelRequested"
    }

    function init() {
        hold.finishHold()
        hold.targetAgentId = "agent-a"
        hold.targetCapabilityId = "capability-a"
        hold.targetSequence = 7
        confirmedSpy.clear()
        cancelledSpy.clear()
        accessibleHoldSpy.clear()
        voice.pressOwned = false
        voice.voice = {
            "available": true,
            "state": "idle",
            "owned": false
        }
        voice.actionsEnabled = true
        voiceStartSpy.clear()
        voiceStopSpy.clear()
        voiceCancelSpy.clear()
        hostileCard.enabled = true
        agentFocusSpy.clear()
        chatGptButton.enabled = true
        chatGptButton.pending = false
        claudeButton.enabled = true
        claudeButton.pending = false
        chatGptSpy.clear()
        claudeSpy.clear()
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

    function test_agentCardUsesAuthoritativeStateAgeWithoutGenericSummary() {
        compare(hostileCard.processLine(), "WORKING  ·  1S IN STATE")
        compare(hostileCard.contextLine(), "<b>workspace</b>")
    }

    function test_agentCardHasOneWholeCardFocusAction() {
        verify(hostileCard.requestFocus())
        compare(agentFocusSpy.count, 1)
        compare(
            agentFocusSpy.signalArguments[0][0],
            "hostile-agent"
        )
    }

    function test_agentCardPointerTargetFillsCard() {
        var target = findChild(hostileCard, "wholeCardFocusTarget")
        verify(target !== null)
        compare(target.enabled, true)
        compare(target.width, hostileCard.width)
        compare(target.height, hostileCard.height)
        compare(target.z, 10)
    }

    function test_desktopAppButtonsEmitOnceAndRespectPendingState() {
        verify(chatGptButton.activate())
        compare(chatGptSpy.count, 1)
        compare(claudeSpy.count, 0)

        chatGptButton.pending = true
        verify(!chatGptButton.activate())
        compare(chatGptSpy.count, 1)

        verify(claudeButton.activate())
        compare(claudeSpy.count, 1)
        claudeButton.enabled = false
        verify(!claudeButton.activate())
        compare(claudeSpy.count, 1)
    }

    function test_disabledAccessibleActionsCannotReachHiddenControls() {
        hostileCard.enabled = false
        verify(!hostileCard.requestFocus())
        compare(agentFocusSpy.count, 0)

        voice.actionsEnabled = false
        verify(!voice.accessibleToggle())
        compare(voiceStartSpy.count, 0)
        compare(voiceStopSpy.count, 0)
        compare(voiceCancelSpy.count, 0)

    }

    function test_voicePressPairsExactlyOneStartAndStop() {
        verify(voice.beginPress())
        verify(!voice.beginPress())
        compare(voiceStartSpy.count, 1)
        verify(voice.finishPress())
        verify(!voice.finishPress())
        compare(voiceStopSpy.count, 1)
    }

    function test_voicePressRequiresIdleAvailableState() {
        voice.voice = {
            "available": false,
            "state": "unavailable",
            "owned": false
        }
        verify(!voice.beginPress())
        compare(voiceStartSpy.count, 0)

        voice.voice = {
            "available": true,
            "state": "processing",
            "owned": true
        }
        verify(!voice.beginPress())
        compare(voiceStartSpy.count, 0)
    }

    function test_voiceErrorCanBeRetriedExactlyOnce() {
        voice.voice = {
            "state": "error",
            "available": true,
            "owned": false
        }
        verify(voice.beginPress())
        verify(!voice.beginPress())
        compare(voiceStartSpy.count, 1)
        verify(voice.finishPress())
        compare(voiceStopSpy.count, 1)
    }

    function test_ownedVoiceErrorCanOnlyCancel() {
        voice.voice = {
            "state": "error",
            "available": true,
            "owned": true
        }
        verify(!voice.beginPress())
        verify(voice.accessibleToggle())
        compare(voiceStartSpy.count, 0)
        compare(voiceStopSpy.count, 0)
        compare(voiceCancelSpy.count, 1)
    }
}
