import QtQuick
import QtTest
import "../components"
import "../components/PortalPalette.js" as Palette

TestCase {
    name: "PortalPalette"

    property var semanticTheme: ({
        "blue": "#123456",
        "yellow": "#654321",
        "green": "#246813",
        "red": "#975310",
        "magenta": "#864209",
        "cyan": "#135724",
        "muted": "#555555",
        "border": "#333333",
        "surface": "#111111",
        "textPrimary": "#eeeeee"
    })

    AmbientRing {
        id: halo

        width: 2560
        height: 720
        reducedMotion: true
        connectionState: "connected"
        voice: ({"state": "idle"})
        theme: semanticTheme
    }

    function agent(status, reviewReady) {
        return {
            "status": status,
            "review_ready": reviewReady === true
        }
    }

    function init() {
        halo.suppressRunners = false
        halo.agents = []
    }

    function cleanup() {
        halo.suppressRunners = false
        halo.agents = []
    }

    function test_agentColorsFollowThemeSemanticRoles() {
        compare(
            String(Palette.agentColor(agent("working"), semanticTheme)),
            semanticTheme.blue
        )
        compare(
            String(Palette.agentColor(agent("blocked"), semanticTheme)),
            semanticTheme.yellow
        )
        compare(
            String(Palette.agentColor(agent("done", true), semanticTheme)),
            semanticTheme.green
        )
        compare(
            String(Palette.agentColor(agent("done", false), semanticTheme)),
            semanticTheme.muted
        )
        compare(
            String(Palette.agentColor(agent("unknown"), semanticTheme)),
            semanticTheme.magenta
        )
    }

    function test_ambientColorsFollowThemeSemanticRoles() {
        compare(Palette.ambientColor("working", semanticTheme), semanticTheme.blue)
        compare(Palette.ambientColor("blocked", semanticTheme), semanticTheme.yellow)
        compare(Palette.ambientColor("review", semanticTheme), semanticTheme.green)
        compare(Palette.ambientColor("error", semanticTheme), semanticTheme.red)
        compare(
            Palette.ambientColor("voice-processing", semanticTheme),
            semanticTheme.cyan
        )
        compare(
            Palette.ambientColor("voice-recording", semanticTheme),
            semanticTheme.green
        )
        compare(
            Palette.ambientColor("off", semanticTheme),
            semanticTheme.muted
        )
    }

    function test_reviewReadyOverridesIdleButNotActiveAttention() {
        compare(Palette.effectiveAgentState(agent("idle", true)), "review")
        compare(Palette.effectiveAgentState(agent("working", true)), "working")
        compare(Palette.effectiveAgentState(agent("blocked", true)), "blocked")
        compare(Palette.effectiveAgentState(agent("done", false)), "idle")
    }

    function test_voiceOverridesAggregateRing() {
        var agents = [agent("blocked"), agent("working")]
        compare(Palette.ambientMode(
            agents,
            {"state": "recording"},
            "connected"
        ), "voice-recording")
        compare(Palette.ambientMode(
            agents,
            {"state": "processing"},
            "connected"
        ), "voice-processing")
        compare(Palette.ambientMode(
            agents,
            {"state": "error"},
            "connected"
        ), "voice-error")
    }

    function test_aggregateRingUsesMicroAttentionPriority() {
        compare(Palette.ambientMode(
            [agent("working"), agent("idle")],
            {"state": "idle"},
            "connected"
        ), "working")
        compare(Palette.ambientMode(
            [agent("working"), agent("idle", true)],
            {"state": "idle"},
            "connected"
        ), "review")
        compare(Palette.ambientMode(
            [agent("blocked"), agent("idle", true)],
            {"state": "idle"},
            "connected"
        ), "blocked")
    }

    function test_perimeterHaloRunsOnlyForNonIdleAgentExecution() {
        compare(Palette.perimeterMode([]), "off")
        compare(Palette.perimeterMode([agent("idle")]), "off")
        compare(Palette.perimeterMode([agent("idle", true)]), "off")
        compare(Palette.perimeterMode([agent("done", true)]), "off")
        compare(
            Palette.perimeterMode([agent("working"), agent("idle")]),
            "working"
        )
        compare(
            Palette.perimeterMode([agent("working"), agent("blocked")]),
            "blocked"
        )
    }

    function test_perimeterHaloHasTwoOpposingClockwiseRunners() {
        halo.agents = [agent("working")]
        compare(halo.active, true)
        compare(halo.moving, false)
        compare(halo.runnerCount, 2)
        compare(halo.runnerOffset, 0.5)
        compare(halo.particleCountPerRunner, 6)
        compare(halo.glowBlurMax, 48)

        halo.suppressRunners = true
        compare(halo.active, false)
        compare(halo.moving, false)

        halo.suppressRunners = false
        compare(halo.active, true)

        var start = halo.perimeterPoint(0, halo.width, halo.height, 22)
        var later = halo.perimeterPoint(0.1, halo.width, halo.height, 22)
        compare(start.y, 0)
        compare(later.y, 0)
        verify(later.x > start.x)

        halo.agents = [agent("idle")]
        compare(halo.active, false)
        compare(halo.moving, false)
    }
}
