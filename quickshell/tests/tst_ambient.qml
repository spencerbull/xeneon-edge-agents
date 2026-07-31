import QtQuick
import QtTest
import "../components"

TestCase {
    id: testCase

    name: "AmbientPresentation"
    width: 2560
    height: 720

    AmbientView {
        id: ambient

        width: testCase.width
        height: testCase.height
        reducedMotion: true
        health: ({"status": "healthy"})
        voice: ({
            "available": true,
            "state": "idle",
            "owned": false
        })
        connectionState: "connected"
    }

    AmbientAgentNode {
        id: reviewNode

        agent: ({
            "id": "review-node",
            "display_name": "<review-ready>",
            "status": "idle",
            "review_ready": true
        })
        reveal: 1
        reducedMotion: true
    }

    OrbitTrail {
        id: boundedTrail

        width: 800
        height: 400
        reveal: 1
    }

    SignalSpy {
        id: wakeSpy
        target: ambient
        signalName: "wakeRequested"
    }

    function agent(index) {
        return {
            "id": "ambient-" + index,
            "display_name": "Ambient " + index,
            "status": index === 0 ? "working" : "idle",
            "review_ready": index === 1
        }
    }

    function sevenAgents() {
        var result = []
        for (var index = 0; index < 7; index += 1)
            result.push(agent(index))
        return result
    }

    function init() {
        ambient.reducedMotion = true
        ambient.active = false
        ambient.orbitPhase = 0.125
        ambient.orbitBoostPhase = 0
        ambient.motionEnergy = 0
        ambient.frozenBoostPhase = 0
        ambient.exitCoastPhase = 0
        ambient.agents = sevenAgents()
        ambient.health = {"status": "healthy"}
        ambient.voice = {
            "available": true,
            "state": "idle",
            "owned": false
        }
        ambient.connectionState = "connected"
        wakeSpy.clear()
        tryCompare(ambient, "revealProgress", 0)
    }

    function test_capsConstellationAtSixAgents() {
        compare(ambient.nodeLimit, 6)
        compare(ambient.visibleAgentCount, 6)
        verify(findChild(ambient, "ambientAgentNode-5") !== null)
        compare(findChild(ambient, "ambientAgentNode-6"), null)
    }

    function test_reviewReadyUsesExactPaletteAndPlainText() {
        compare(reviewNode.agentState, "review")
        compare(String(reviewNode.accent), "#00ff00")

        var label = findChild(reviewNode, "ambientAgentDisplayName")
        verify(label !== null)
        compare(label.text, "<REVIEW-READY>")
        compare(label.textFormat, Text.PlainText)
    }

    function test_voiceAndConnectionDriveCentralTreatment() {
        ambient.voice = {
            "available": true,
            "state": "recording",
            "owned": true
        }
        compare(ambient.mode, "voice-recording")
        compare(String(ambient.modeAccent), "#2e8b57")
        compare(ambient.centerTitle(), "VOICE")
        compare(ambient.centerDetail(), "VOICE // RECORDING")

        ambient.voice = {
            "available": true,
            "state": "idle",
            "owned": false
        }
        ambient.connectionState = "offline"
        compare(ambient.mode, "error")
        compare(String(ambient.modeAccent), "#ff2020")
        compare(ambient.centerTitle(), "ATTENTION")
    }

    function test_nodesMoveClockwiseAtIndependentRates() {
        ambient.orbitPhase = 0
        var firstStart = ambient.nodeAngleDegrees(0)
        var secondStart = ambient.nodeAngleDegrees(1)

        ambient.orbitPhase = 0.25
        var firstDelta = ambient.nodeAngleDegrees(0) - firstStart
        var secondDelta = ambient.nodeAngleDegrees(1) - secondStart

        verify(firstDelta > 0)
        verify(secondDelta > 0)
        verify(Math.abs(firstDelta - secondDelta) > 1)
    }

    function test_phaseWrapsAreGeometricallyContinuous() {
        ambient.motionEnergy = 0
        ambient.orbitPhase = 1
        var quietEnd = normalizedAngle(ambient.nodeAngleDegrees(1))
        ambient.orbitPhase = 0
        var quietStart = normalizedAngle(ambient.nodeAngleDegrees(1))
        fuzzyCompare(quietEnd, quietStart, 0.0001)

        ambient.motionEnergy = 1
        ambient.orbitBoostPhase = 1
        var boostEnd = normalizedAngle(ambient.nodeAngleDegrees(3))
        ambient.orbitBoostPhase = 0
        var boostStart = normalizedAngle(ambient.nodeAngleDegrees(3))
        fuzzyCompare(boostEnd, boostStart, 0.0001)
    }

    function test_reducedMotionUsesFinalStaticComposition() {
        ambient.active = true
        tryCompare(ambient, "revealProgress", 1)
        compare(ambient.curtainProgress, 1)
        compare(ambient.ringProgress, 1)
        compare(ambient.centerProgress, 1)
        compare(ambient.nodeProgress, 1)
        compare(ambient.orbiting, false)
        compare(ambient.orbitPhase, 0.125)
        compare(ambient.orbitBoostPhase, 0)
        compare(ambient.motionEnergy, 0)
    }

    function test_ringRevealUsesEaseOutGrowth() {
        var linearMidpoint = ambient.stage(0.4, 0.18, 0.62)
        verify(ambient.easeOut(linearMidpoint) > linearMidpoint)
    }

    function test_controlCenterRevealIsAStagedReverseTransition() {
        ambient.reducedMotion = false
        compare(ambient.controlCenterProgressAt(1, true), 0)
        compare(ambient.controlCenterProgressAt(1, false), 0)
        compare(ambient.controlCenterProgressAt(0, false), 1)
        compare(ambient.controlCenterProgressAt(0, true), 1)
        compare(ambient.controlCenterProgressAt(0.5, false), 0)
        verify(ambient.controlCenterProgressAt(0.3, false) > 0.5)
        verify(ambient.controlCenterProgressAt(0.1, false) > 0.98)
        verify(ambient.exitDurationMs >= 900)
    }

    function test_exitCoastNeverRewindsBoostAngle() {
        ambient.reducedMotion = false
        ambient.active = false
        ambient.orbitPhase = 0.4
        ambient.frozenBoostPhase = 0.75
        ambient.exitCoastPhase = 0
        var startAngle = ambient.nodeAngleDegrees(3)

        ambient.motionEnergy = 0
        compare(ambient.nodeAngleDegrees(3), startAngle)

        ambient.exitCoastPhase = 0.012
        verify(ambient.nodeAngleDegrees(3) > startAngle)
    }

    function test_fadeOutShieldsCardsUntilCurtainIsGone() {
        ambient.reducedMotion = true
        ambient.active = true
        tryCompare(ambient, "revealProgress", 1)

        ambient.reducedMotion = false
        ambient.active = false
        compare(ambient.enabled, true)
        compare(ambient.exitShield, true)
        tryCompare(ambient, "exitShield", false)
        compare(ambient.enabled, false)
    }

    function test_trailsStayBounded() {
        compare(boundedTrail.segmentCount, 8)
        verify(boundedTrail.sweepDegrees <= 90)
    }

    function normalizedAngle(angle) {
        var normalized = angle % 360
        return normalized < 0 ? normalized + 360 : normalized
    }
}
