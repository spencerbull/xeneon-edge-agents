import QtQuick
import QtTest
import "../components"

TestCase {
    id: testCase

    name: "AiUsageDock"
    width: 2560
    height: 140

    AiUsageDock {
        id: dock

        width: 2512
        height: 106
        reducedMotion: true
        agents: [
            {"focused": true},
            {"focused": false}
        ]
        sessions: [{}, {}]
    }

    function init() {
        dock.usage = {
            "providers": [{
                "id": "claude",
                "label": "Claude",
                "kind": "quota",
                "available": true,
                "stale": false,
                "source": "oauth",
                "status": "allowed_warning",
                "primary": {
                    "label": "5h",
                    "utilization": 0.03,
                    "reset_at_ms": Date.now() + 7200000
                },
                "secondary": {
                    "label": "Weekly",
                    "utilization": 0.07,
                    "reset_at_ms": Date.now() + 604800000
                },
                "last_updated_ms": Date.now()
            }, {
                "id": "codex",
                "label": "Codex",
                "kind": "quota",
                "available": true,
                "stale": false,
                "source": "rpc",
                "status": "allowed",
                "plan": "pro",
                "primary": {
                    "label": "Weekly",
                    "utilization": 0.74,
                    "reset_at_ms": Date.now() + 86400000
                },
                "today_tokens": 53960987620,
                "tokens_per_hour": 1778512401,
                "last_updated_ms": Date.now()
            }, {
                "id": "opencode",
                "label": "OpenCode",
                "kind": "local_budget",
                "available": true,
                "stale": true,
                "source": "sqlite",
                "status": "allowed",
                "plan": "local messages",
                "model": "gpt-5.6-sol (openai)",
                "primary": {
                    "label": "5h",
                    "utilization": 0
                },
                "secondary": {
                    "label": "Weekly",
                    "utilization": 0.0022
                },
                "last_updated_ms": Date.now() - 1200000
            }]
        }
    }

    function test_rendersBothWindowsAndAggregateActivity() {
        var claude = findChild(dock, "usageCard_claude")
        var codex = findChild(dock, "usageCard_codex")
        var opencode = findChild(dock, "usageCard_opencode")

        verify(claude !== null)
        verify(codex !== null)
        verify(opencode !== null)
        compare(claude.primaryPercent, 3)
        compare(claude.secondaryPercent, 7)
        compare(claude.statusLabel, "WARNING")
        compare(codex.primaryPercent, 74)
        compare(codex.secondaryPercent, 0)
        compare(
            codex.activityLabel,
            "TODAY 54.0B · RATE 1.78B/H"
        )
        compare(opencode.statusLabel, "STALE")
        compare(opencode.activityLabel, "GPT-5.6-SOL (OPENAI)")
    }

    function test_statusAndFormattingStayBoundedAndExplicit() {
        compare(dock.formatTokens(999), "999")
        compare(dock.formatTokens(12500), "12.5K")
        compare(dock.formatTokens(2500000), "2.50M")
        compare(dock.providerStatus({
            "available": false,
            "status": "rejected",
            "source": "rpc"
        }), "LIMIT REACHED")
        compare(dock.providerStatus({
            "available": false,
            "status": "allowed",
            "source": "unknown"
        }), "UNTRUSTED")
    }

    function test_fleetSummaryUsesAuthoritativeCollections() {
        compare(dock.fleetSummary(), "2 AGENTS · 2 SESSIONS")
        compare(dock.focusedSummary(), "1 FOCUSED")
    }
}
