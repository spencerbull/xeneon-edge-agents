import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures"

REQUIRED_SNAPSHOT_KEYS = {
    "schema_version",
    "type",
    "sequence",
    "daemon_epoch",
    "generated_at_ms",
    "connection",
    "sessions",
    "agents",
    "health",
}
SNAPSHOT_KEYS = REQUIRED_SNAPSHOT_KEYS | {"voice", "usage", "micro"}
REQUIRED_AGENT_KEYS = {
    "id",
    "display_name",
    "agent",
    "status",
    "workspace",
    "session",
    "focused",
    "observed_for_seconds",
    "source_order",
    "actions",
}
AGENT_KEYS = REQUIRED_AGENT_KEYS | {
    "review_ready",
    "launch_pending",
    "repository",
    "worktree",
}
HEALTH_KEYS = {
    "cpu",
    "cpu_temperature",
    "gpu",
    "gpu_temperature",
    "memory",
    "network_down",
    "network_up",
    "battery",
}
AGENT_STATUSES = {"blocked", "done", "working", "idle", "unknown"}
CONNECTION_STATES = {"connected", "degraded", "reconnecting", "offline"}
SESSION_STATES = {"connected", "stale", "incompatible", "offline"}
FORBIDDEN_KEYS = {
    "terminal",
    "terminal_text",
    "prompt",
    "prompt_text",
    "pane_text",
    "raw_text",
    "keys",
}


def envelopes(path: pathlib.Path) -> list[dict]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def nested_keys(value):
    if isinstance(value, dict):
        for key, nested in value.items():
            yield key
            yield from nested_keys(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from nested_keys(nested)


class FixtureContractTests(unittest.TestCase):
    def test_all_fixture_lines_are_schema_v1_ndjson(self):
        fixture_paths = sorted(FIXTURES.glob("*.ndjson"))
        self.assertGreaterEqual(len(fixture_paths), 6)
        for path in fixture_paths:
            with self.subTest(path=path.name):
                parsed = envelopes(path)
                self.assertTrue(parsed)
                for envelope in parsed:
                    self.assertEqual(envelope["schema_version"], 1)
                    self.assertIn(
                        envelope["type"],
                        {"snapshot", "action_result"},
                    )
                    self.assertFalse(
                        FORBIDDEN_KEYS.intersection(nested_keys(envelope))
                    )

    def test_snapshots_match_canonical_v1_shapes(self):
        for path in sorted(FIXTURES.glob("*.ndjson")):
            for envelope in envelopes(path):
                if envelope["type"] != "snapshot":
                    continue
                with self.subTest(path=path.name):
                    self.assertLessEqual(
                        REQUIRED_SNAPSHOT_KEYS,
                        set(envelope),
                    )
                    self.assertLessEqual(set(envelope), SNAPSHOT_KEYS)
                    self.assertIn(
                        envelope["connection"],
                        CONNECTION_STATES,
                    )
                    self.assertIsInstance(envelope["sessions"], list)
                    self.assertIsInstance(envelope["agents"], list)
                    self.assertEqual(set(envelope["health"]), HEALTH_KEYS)
                    if "voice" in envelope:
                        self.assertIn(
                            envelope["voice"]["state"],
                            {
                                "idle",
                                "recording",
                                "processing",
                                "error",
                                "unavailable",
                            },
                        )
                        self.assertIsInstance(
                            envelope["voice"]["owned"],
                            bool,
                        )
                    if "usage" in envelope:
                        providers = envelope["usage"]["providers"]
                        self.assertLessEqual(len(providers), 3)
                        self.assertEqual(
                            [provider["id"] for provider in providers],
                            ["claude", "codex", "opencode"][: len(providers)],
                        )
                        for provider in providers:
                            self.assertIn(
                                provider["kind"],
                                {"quota", "local_budget"},
                            )
                            self.assertIsInstance(provider["available"], bool)
                            self.assertIsInstance(provider["stale"], bool)
                            for name in ("primary", "secondary"):
                                window = provider.get(name)
                                if window is None:
                                    continue
                                self.assertGreaterEqual(
                                    window["utilization"],
                                    0,
                                )
                                self.assertLessEqual(
                                    window["utilization"],
                                    1,
                                )
                    if "micro" in envelope:
                        micro = envelope["micro"]
                        self.assertIsInstance(micro["connected"], bool)
                        self.assertIsInstance(micro["charging"], bool)
                        if "battery" in micro:
                            self.assertGreaterEqual(micro["battery"], 0)
                            self.assertLessEqual(micro["battery"], 100)

                    for session in envelope["sessions"]:
                        self.assertTrue(session["name"])
                        self.assertIn(session["state"], SESSION_STATES)

                    for agent in envelope["agents"]:
                        self.assertLessEqual(
                            REQUIRED_AGENT_KEYS,
                            set(agent),
                        )
                        self.assertLessEqual(set(agent), AGENT_KEYS)
                        self.assertIn(agent["status"], AGENT_STATUSES)
                        self.assertIsInstance(agent["focused"], bool)
                        if "review_ready" in agent:
                            self.assertIsInstance(
                                agent["review_ready"],
                                bool,
                            )
                        if "launch_pending" in agent:
                            self.assertIsInstance(
                                agent["launch_pending"],
                                bool,
                            )
                        self.assertEqual(
                            set(agent["actions"]),
                            {"open", "zoom", "approve", "interrupt"},
                        )
                        self.assertIsInstance(agent["actions"]["open"], bool)
                        self.assertIsInstance(agent["actions"]["zoom"], bool)
                        for action in ("approve", "interrupt"):
                            record = agent["actions"][action]
                            if record is None:
                                continue
                            self.assertEqual(record["kind"], action)
                            self.assertTrue(record["capability_id"])
                            self.assertGreaterEqual(
                                record["expires_at_ms"],
                                0,
                            )
                            self.assertGreaterEqual(
                                record["expected_revision"],
                                0,
                            )

                    for metric in envelope["health"].values():
                        self.assertIsInstance(metric["available"], bool)
                        self.assertIsInstance(metric["unit"], str)
                        if metric["available"]:
                            self.assertIsInstance(
                                metric["value"],
                                (int, float),
                            )
                        else:
                            self.assertNotIn("value", metric)

    def test_action_results_match_canonical_v1_shape(self):
        expected = {
            "schema_version",
            "type",
            "request_id",
            "ok",
            "code",
            "message",
        }
        results = []
        for path in sorted(FIXTURES.glob("*.ndjson")):
            results.extend(
                envelope
                for envelope in envelopes(path)
                if envelope["type"] == "action_result"
            )
        self.assertTrue(results)
        for result in results:
            self.assertEqual(set(result), expected)
            self.assertIsInstance(result["ok"], bool)

    def test_named_contract_fixtures_cover_required_states(self):
        snapshot = envelopes(FIXTURES / "snapshot.ndjson")[0]
        paging = envelopes(FIXTURES / "agents.ndjson")[0]
        degraded = envelopes(FIXTURES / "health.ndjson")[0]
        empty = envelopes(FIXTURES / "empty.ndjson")[0]
        disconnected = envelopes(FIXTURES / "disconnected.ndjson")[0]
        action_envelopes = envelopes(FIXTURES / "action_result.ndjson")
        voice = envelopes(FIXTURES / "voice.ndjson")[0]
        home = envelopes(FIXTURES / "home.ndjson")[0]

        self.assertEqual(snapshot["type"], "snapshot")
        self.assertEqual(len(snapshot["agents"]), 6)
        self.assertGreater(len(paging["agents"]), 6)
        self.assertEqual(degraded["connection"], "degraded")
        self.assertFalse(degraded["health"]["gpu_temperature"]["available"])
        self.assertEqual(empty["agents"], [])
        self.assertEqual(empty["connection"], "connected")
        self.assertEqual(disconnected["connection"], "offline")
        self.assertEqual(voice["voice"]["state"], "recording")
        self.assertTrue(voice["voice"]["owned"])
        self.assertEqual(
            [provider["id"] for provider in home["usage"]["providers"]],
            ["claude", "codex", "opencode"],
        )
        self.assertTrue(home["micro"]["connected"])
        self.assertTrue(voice["agents"][0]["review_ready"])
        self.assertEqual(
            [
                voice["voice"]["state"],
                envelopes(FIXTURES / "voice_processing.ndjson")[0]["voice"][
                    "state"
                ],
                envelopes(FIXTURES / "voice_error.ndjson")[0]["voice"]["state"],
                envelopes(FIXTURES / "voice_idle.ndjson")[0]["voice"]["state"],
            ],
            ["recording", "processing", "error", "idle"],
        )
        self.assertTrue(
            any(item["type"] == "action_result" for item in action_envelopes)
        )

    def test_agents_are_attention_ranked_like_the_daemon(self):
        def attention_rank(agent):
            status = agent["status"]
            review_ready = agent.get(
                "review_ready",
                status == "done",
            )
            if status == "blocked":
                return 0
            if review_ready and status in {"done", "idle"}:
                return 1
            if status == "working":
                return 2
            if status in {"done", "idle"}:
                return 3
            return 4

        for path in sorted(FIXTURES.glob("*.ndjson")):
            for envelope in envelopes(path):
                if envelope["type"] != "snapshot":
                    continue
                actual = [
                    (
                        attention_rank(agent),
                        agent["source_order"],
                        agent["id"],
                    )
                    for agent in envelope["agents"]
                ]
                with self.subTest(path=path.name):
                    self.assertEqual(actual, sorted(actual))

    def test_approval_capabilities_are_explicitly_simulated(self):
        for path in sorted(FIXTURES.glob("*.ndjson")):
            for envelope in envelopes(path):
                if envelope["type"] != "snapshot":
                    continue
                for agent in envelope["agents"]:
                    if agent["actions"]["approve"] is None:
                        continue
                    marker = " ".join(
                        [agent["display_name"], agent["agent"], agent["session"]]
                    ).lower()
                    self.assertIn("simulated", marker)


if __name__ == "__main__":
    unittest.main()
