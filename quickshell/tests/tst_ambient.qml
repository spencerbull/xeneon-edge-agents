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

    function fourteenAgents() {
        var result = []
        for (var index = 0; index < 14; index += 1)
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

    function verifyNodeBounds(count, reduced, phase, boostPhase) {
        ambient.agents = fourteenAgents().concat([
            agent(14), agent(15), agent(16), agent(17), agent(18)
        ]).slice(0, count)
        ambient.reducedMotion = reduced
        ambient.orbitPhase = phase
        ambient.orbitBoostPhase = boostPhase === undefined ? phase / 2 : boostPhase
        ambient.motionEnergy = reduced ? 0 : 1
        wait(0)
        var constellation = findChild(ambient, "ambientConstellation")
        verify(constellation !== null)
        var visible = Math.min(14, count)
        for (var firstIndex = 0; firstIndex < visible; firstIndex += 1) {
            var first = findChild(ambient, "ambientAgentNode-" + firstIndex)
            verify(first !== null)
            var halo = first.dense ? 8 : 12
            verify(first.x - halo >= -0.5)
            verify(first.y - halo >= -0.5)
            verify(
                first.x + first.width + halo
                    <= constellation.width + 0.5
            )
            verify(
                first.y + first.height + halo
                    <= constellation.height + 0.5
            )
        }
    }

    function test_capsConstellationAtFourteenIndependentLanes() {
        ambient.agents = fourteenAgents().concat([agent(14)])
        ambient.reducedMotion = false
        compare(ambient.nodeLimit, 14)
        compare(ambient.visibleAgentCount, 14)
        compare(ambient.denseConstellation, true)
        verify(findChild(ambient, "ambientAgentNode-13") !== null)
        compare(findChild(ambient, "ambientAgentNode-14"), null)
        compare(ambient.radiusXFor(0), 720)
        compare(ambient.radiusXFor(7), 680)
        compare(ambient.radiusYFor(0), 190)
        compare(ambient.radiusYFor(7), 200)
        var denseSpeeds = [1, 2, 1, 3, 2, 1, 2, 3, 1, 2, 3, 1, 2, 3]
        var denseRadiiX = [
            720, 800, 660, 780, 700, 820, 750,
            680, 810, 730, 770, 650, 790, 710
        ]
        var denseRadiiY = [
            190, 230, 205, 242, 215, 185, 235,
            200, 225, 195, 240, 210, 180, 220
        ]
        for (var lane = 0; lane < 14; lane += 1) {
            compare(ambient.speedFor(lane), denseSpeeds[lane])
            compare(ambient.radiusXFor(lane), denseRadiiX[lane])
            compare(ambient.radiusYFor(lane), denseRadiiY[lane])
        }

        var constellation = findChild(ambient, "ambientConstellation")
        verify(constellation !== null)
        for (var index = 0; index < 14; index += 1) {
            var node = findChild(ambient, "ambientAgentNode-" + index)
            verify(node !== null)
            verify(node.x >= -0.5)
            verify(node.y >= -0.5)
            verify(node.x + node.width <= constellation.width + 0.5)
            verify(node.y + node.height <= constellation.height + 0.5)
        }
    }

    function test_constellationStaysBoundedAcrossCountsAndPhases() {
        var phases = [0, 0.071, 0.125, 0.2143, 0.333, 0.5, 0.875]
        for (var sparseCount = 1; sparseCount <= 6; sparseCount += 1) {
            verifyNodeBounds(sparseCount, true, 0)
            for (var sparsePhase = 0;
                    sparsePhase < phases.length; sparsePhase += 1) {
                verifyNodeBounds(
                    sparseCount,
                    false,
                    phases[sparsePhase],
                    phases[(sparsePhase + 2) % phases.length]
                )
            }
        }
        for (var count = 7; count <= 14; count += 1) {
            verifyNodeBounds(count, true, 0)
            for (var phaseIndex = 0;
                    phaseIndex < phases.length; phaseIndex += 1) {
                verifyNodeBounds(count, false, phases[phaseIndex])
                verifyNodeBounds(
                    count,
                    false,
                    phases[phaseIndex],
                    phases[(phaseIndex + 3) % phases.length]
                )
            }
        }
        verifyNodeBounds(19, true, 0)
        verifyNodeBounds(19, false, 0.2143)
    }

    function test_reviewReadyUsesExactPaletteAndPlainText() {
        compare(reviewNode.agentState, "review")
        compare(String(reviewNode.accent), String(reviewNode.theme.green))

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
        compare(String(ambient.modeAccent), String(ambient.theme.green))
        compare(ambient.centerTitle(), "VOICE")
        compare(ambient.centerDetail(), "VOICE // RECORDING")

        ambient.voice = {
            "available": true,
            "state": "idle",
            "owned": false
        }
        ambient.connectionState = "offline"
        compare(ambient.mode, "error")
        compare(String(ambient.modeAccent), String(ambient.theme.red))
        compare(ambient.centerTitle(), "ATTENTION")
    }

    function test_denseNodesUseIndependentLegacyStyleLanes() {
        ambient.agents = fourteenAgents()
        ambient.reducedMotion = false
        ambient.orbitPhase = 0
        var firstStart = ambient.nodeAngleDegrees(0)
        var secondStart = ambient.nodeAngleDegrees(1)

        ambient.orbitPhase = 0.125
        var firstDelta = ambient.nodeAngleDegrees(0) - firstStart
        var secondDelta = ambient.nodeAngleDegrees(1) - secondStart

        verify(firstDelta > 0)
        verify(secondDelta > 0)
        verify(secondDelta > firstDelta)
        compare(ambient.speedFor(0), 1)
        compare(ambient.speedFor(1), 2)
        compare(ambient.speedFor(3), 3)
        verify(ambient.radiusXFor(0) !== ambient.radiusXFor(7))
    }

    function test_sixAgentMotionRestoresExactIndependentOriginalLanes() {
        ambient.agents = sevenAgents().slice(0, 6)
        ambient.reducedMotion = false
        ambient.orbitPhase = 0
        compare(ambient.denseConstellation, false)
        var speeds = [1, 2, 1, 3, 2, 1]
        var angles = [-88, -30, 30, 92, 154, 214]
        var radiiX = [410, 530, 650, 470, 600, 510]
        var radiiY = [152, 205, 174, 238, 214, 188]
        for (var index = 0; index < 6; index += 1) {
            compare(ambient.speedFor(index), speeds[index])
            compare(ambient.baseAngleFor(index), angles[index])
            compare(ambient.radiusXFor(index), radiiX[index])
            compare(ambient.radiusYFor(index), radiiY[index])
        }

        var firstStart = ambient.nodeAngleDegrees(0)
        var secondStart = ambient.nodeAngleDegrees(1)
        ambient.orbitPhase = 0.125
        verify(ambient.nodeAngleDegrees(0) > firstStart)
        verify(ambient.nodeAngleDegrees(1) > secondStart)
        verify(
            ambient.nodeAngleDegrees(1) - secondStart
                > ambient.nodeAngleDegrees(0) - firstStart
        )
    }

    function test_reducedMotionEvenlySpacesStaticAgents() {
        ambient.agents = sevenAgents().slice(0, 4)
        ambient.reducedMotion = true
        ambient.orbitPhase = 0.8

        compare(ambient.radiusXFor(0), 520)
        compare(ambient.radiusYFor(0), 230)
        compare(ambient.nodeAngleDegrees(0), -90)
        compare(ambient.nodeAngleDegrees(1), 0)
        compare(ambient.nodeAngleDegrees(2), 90)
        compare(ambient.nodeAngleDegrees(3), 180)

        ambient.orbitPhase = 0.2
        compare(ambient.nodeAngleDegrees(0), -90)
        compare(ambient.nodeAngleDegrees(3), 180)
    }

    function test_phaseWrapsAreGeometricallyContinuous() {
        ambient.agents = sevenAgents().slice(0, 6)
        ambient.reducedMotion = false
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

        ambient.agents = fourteenAgents()
        ambient.orbitPhase = 1
        var denseOrbitEnd = normalizedAngle(ambient.nodeAngleDegrees(13))
        ambient.orbitPhase = 0
        var denseOrbitStart = normalizedAngle(ambient.nodeAngleDegrees(13))
        fuzzyCompare(denseOrbitEnd, denseOrbitStart, 0.0001)

        ambient.orbitBoostPhase = 1
        var denseBoostEnd = normalizedAngle(ambient.nodeAngleDegrees(10))
        ambient.orbitBoostPhase = 0
        var denseBoostStart = normalizedAngle(ambient.nodeAngleDegrees(10))
        fuzzyCompare(denseBoostEnd, denseBoostStart, 0.0001)
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
        for (var index = 0; index < ambient.visibleAgentCount; index += 1) {
            var trail = findChild(ambient, "ambientOrbitTrail-" + index)
            verify(trail !== null)
            compare(trail.reveal, 0)
        }
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
