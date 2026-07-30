import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures"

SNAPSHOT_KEYS = {
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
                    self.assertEqual(set(envelope), SNAPSHOT_KEYS)
                    self.assertIn(
                        envelope["connection"],
                        CONNECTION_STATES,
                    )
                    self.assertIsInstance(envelope["sessions"], list)
                    self.assertIsInstance(envelope["agents"], list)
                    self.assertEqual(set(envelope["health"]), HEALTH_KEYS)

                    for session in envelope["sessions"]:
                        self.assertTrue(session["name"])
                        self.assertIn(session["state"], SESSION_STATES)

                    for agent in envelope["agents"]:
                        self.assertLessEqual(
                            REQUIRED_AGENT_KEYS,
                            set(agent),
                        )
                        self.assertIn(agent["status"], AGENT_STATUSES)
                        self.assertIsInstance(agent["focused"], bool)
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

        self.assertEqual(snapshot["type"], "snapshot")
        self.assertEqual(len(snapshot["agents"]), 6)
        self.assertGreater(len(paging["agents"]), 6)
        self.assertEqual(degraded["connection"], "degraded")
        self.assertFalse(degraded["health"]["gpu_temperature"]["available"])
        self.assertEqual(empty["agents"], [])
        self.assertEqual(empty["connection"], "connected")
        self.assertEqual(disconnected["connection"], "offline")
        self.assertTrue(
            any(item["type"] == "action_result" for item in action_envelopes)
        )

    def test_agents_are_attention_ranked_like_the_daemon(self):
        status_rank = {
            "blocked": 0,
            "done": 1,
            "working": 2,
            "idle": 3,
            "unknown": 4,
        }
        for path in sorted(FIXTURES.glob("*.ndjson")):
            for envelope in envelopes(path):
                if envelope["type"] != "snapshot":
                    continue
                actual = [
                    (
                        status_rank[agent["status"]],
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
