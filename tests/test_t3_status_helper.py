import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import select
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.parse

HELPER = Path(__file__).parents[1] / 'config/bin/xeneon-t3-status'


def load_helper_module():
    loader = importlib.machinery.SourceFileLoader('xeneon_t3_status_mod', str(HELPER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def create_v2_sqlite(path: Path, threads: list[dict]) -> None:
    conn = sqlite3.connect(str(path))
    cur = conn.cursor()
    cur.executescript(
        """
        CREATE TABLE orchestration_v2_projection_metadata (
            projection_name TEXT,
            schema_version INTEGER,
            last_sequence INTEGER
        );
        INSERT INTO orchestration_v2_projection_metadata VALUES ('thread-projections', 2, 42);
        CREATE TABLE projection_projects (
            project_id TEXT PRIMARY KEY,
            title TEXT,
            workspace_root TEXT,
            deleted_at TEXT
        );
        CREATE TABLE orchestration_v2_projection_threads (
            thread_id TEXT PRIMARY KEY,
            project_id TEXT,
            title TEXT,
            provider_instance_id TEXT,
            default_provider TEXT,
            payload_json TEXT,
            created_at TEXT,
            updated_at TEXT,
            archived_at TEXT,
            deleted_at TEXT
        );
        CREATE TABLE orchestration_v2_projection_runs (
            run_id TEXT PRIMARY KEY,
            thread_id TEXT,
            ordinal INTEGER,
            status TEXT,
            requested_at TEXT,
            completed_at TEXT,
            payload_json TEXT
        );
        CREATE TABLE orchestration_v2_projection_runtime_requests (
            request_id TEXT PRIMARY KEY,
            thread_id TEXT,
            status TEXT
        );
        CREATE TABLE orchestration_v2_projection_subagents (
            subagent_id TEXT PRIMARY KEY,
            thread_id TEXT,
            status TEXT
        );
        """
    )
    cur.execute(
        "INSERT INTO projection_projects VALUES ('proj-1', 'xeneon-edge-agents', '/home/user/xeneon-edge-agents', NULL)"
    )
    for idx, t in enumerate(threads):
        payload = {
            'branch': t.get('branch', 'main'),
            'worktreePath': t.get('worktree_path'),
            'settledAt': t.get('settled_at'),
            'settledOverride': t.get('settled_override'),
            'snoozedUntil': t.get('snoozed_until'),
            'lastVisitedAt': t.get('last_visited_at'),
            'secretPrompt': 'NEVER_LEAK_THIS_PROMPT',
        }
        cur.execute(
            "INSERT INTO orchestration_v2_projection_threads VALUES (?, 'proj-1', ?, ?, ?, ?, ?, ?, NULL, NULL)",
            (
                t['id'],
                t['title'],
                t.get('provider', 'claude'),
                'claude',
                json.dumps(payload),
                t.get('updated_at', '2026-11-27T18:00:00Z'),
                t.get('updated_at', '2026-11-27T18:00:00Z'),
            ),
        )
        cur.execute(
            "INSERT INTO orchestration_v2_projection_runs VALUES (?, ?, ?, ?, ?, ?, '{}')",
            (
                f'run-{idx}',
                t['id'],
                idx + 1,
                t.get('run_status', 'running'),
                t.get('updated_at', '2026-11-27T18:00:00Z'),
                t.get('completed_at'),
            ),
        )
    conn.commit()
    conn.close()


class StatusHelperTests(unittest.TestCase):
    def run_helper(self, child_body):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        child = root / 'fake-t3'
        child.write_text('#!/usr/bin/python3\nimport os, signal, sys\n' + child_body)
        child.chmod(0o700)
        output = root / 'status.json'
        output.write_text('old status')
        helper = subprocess.Popen(
            [
                '/usr/bin/python3',
                str(HELPER),
                '--t3-bin',
                str(child),
                '--t3-home',
                str(root),
                '--output',
                str(output),
            ],
            stderr=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            env={**os.environ, 'XDG_RUNTIME_DIR': str(root)},
            start_new_session=True,
        )

        def cleanup():
            try:
                os.killpg(helper.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            helper.wait()
            helper.stderr.close()

        self.addCleanup(cleanup)
        return helper, output

    def test_stop_reaps_silent_child_even_when_it_keeps_stdout_open(self):
        helper, output = self.run_helper(
            'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
            'print(os.getpid(), file=sys.stderr, flush=True)\n'
            'while True: signal.pause()\n'
        )
        self.assertTrue(select.select([helper.stderr], [], [], 5)[0], 'fake CLI did not start')
        child_pid = int(helper.stderr.readline())
        helper.terminate()
        self.assertEqual(helper.wait(timeout=7), 0)
        self.assertFalse(output.exists())
        with self.assertRaises(ProcessLookupError):
            os.kill(child_pid, 0)

    def test_eof_and_invalid_frames_remove_output(self):
        valid = {'schema_version': 1, 'environment_id': 'test', 'generated_at_ms': 0, 'threads': []}
        for frame in [json.dumps(valid) + '\n', '{invalid}\n', 'x' * 4_194_305]:
            with self.subTest(size=len(frame)):
                helper, output = self.run_helper('sys.stdout.write(' + repr(frame) + ')\nsys.stdout.flush()\n')
                self.assertNotEqual(helper.wait(timeout=7), 0)
                self.assertFalse(output.exists())


class FleetCollectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_helper_module()

    def test_dpop_key_generates_valid_es256_proof_and_thumbprint(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = self.mod.DpopKey(Path(tmp) / 'dpop-key.pem')
            proof = key.proof('POST', 'https://relay.t3.codes/v1/environments/abc/status?foo=1', access_token='tok-123')
            parts = proof.split('.')
            self.assertEqual(len(parts), 3)
            header = json.loads(base64.urlsafe_b64decode(parts[0] + '=='))
            payload = json.loads(base64.urlsafe_b64decode(parts[1] + '=='))
            sig = base64.urlsafe_b64decode(parts[2] + '==')
            self.assertEqual(header['typ'], 'dpop+jwt')
            self.assertEqual(header['alg'], 'ES256')
            self.assertEqual(header['jwk']['kty'], 'EC')
            self.assertEqual(header['jwk']['crv'], 'P-256')
            self.assertEqual(payload['htm'], 'POST')
            self.assertEqual(payload['htu'], 'https://relay.t3.codes/v1/environments/abc/status')
            self.assertIn('ath', payload)
            self.assertEqual(len(sig), 64)
            self.assertEqual(len(key.thumbprint()), 43)
            self.assertEqual(os.stat(Path(tmp) / 'dpop-key.pem').st_mode & 0o777, 0o600)

    def test_shell_extraction_strips_private_messages_and_settled_threads(self):
        payload = {
            'projects': [
                {'id': 'p1', 'title': 'omabot', 'workspaceRoot': '/home/sbull/omabot', 'deletedAt': None}
            ],
            'threads': [
                {
                    'id': 'thr-live',
                    'projectId': 'p1',
                    'title': 'Diagnose Speaker Failure',
                    'providerInstanceId': 'codex',
                    'branch': 'fix/audio',
                    'worktreePath': None,
                    'status': 'running',
                    'activityRunStatus': 'running',
                    'pendingRuntimeRequest': None,
                    'pendingBackgroundTasks': [],
                    'latestVisibleMessage': {
                        'id': 'm1',
                        'role': 'assistant',
                        'text': 'SUPER_SECRET_PRIVATE_TRANSCRIPT',
                        'updatedAt': '2026-11-27T18:10:00Z',
                    },
                    'lastError': 'PRIVATE_TRACEBACK',
                    'updatedAt': '2026-11-27T18:10:00Z',
                    'latestRunCompletedAt': None,
                    'lastVisitedAt': None,
                    'settledAt': None,
                    'settledOverride': None,
                    'deletedAt': None,
                    'archivedAt': None,
                },
                {
                    'id': 'thr-settled',
                    'projectId': 'p1',
                    'title': 'Old Settled Thread',
                    'providerInstanceId': 'claude',
                    'status': 'idle',
                    'pendingRuntimeRequest': None,
                    'settledAt': '2026-11-27T17:00:00Z',
                    'settledOverride': 'settled',
                    'updatedAt': '2026-11-27T17:00:00Z',
                    'deletedAt': None,
                    'archivedAt': None,
                },
            ],
        }
        rows = self.mod.extract_shell_threads(payload, 'env-xps', 'xps-grace', device_local=False)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row['thread_id'], 'thr-live')
        self.assertEqual(row['device_label'], 'xps-grace')
        self.assertFalse(row['device_local'])
        self.assertEqual(row['status'], 'working')
        self.assertTrue(row['background_work'])
        serialized = json.dumps(rows)
        self.assertNotIn('SUPER_SECRET_PRIVATE_TRANSCRIPT', serialized)
        self.assertNotIn('PRIVATE_TRACEBACK', serialized)

    def test_fleet_collector_merges_local_tier1_shell_tier2_fallback_and_offline_devices(self):
        test_case = self

        class MockRelayHandler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                pass

            def send_json(self, code: int, body: dict):
                raw = json.dumps(body).encode('utf-8')
                self.send_response(code)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                if parsed.path == '/v1/environments':
                    self.send_json(200, {
                        'environments': [
                            {'environmentId': 'env-saber', 'label': 'saber', 'endpoint': {'httpBaseUrl': base_url + '/remote/saber', 'wsBaseUrl': 'ws://x', 'providerKind': 't3_relay'}},
                            {'environmentId': 'env-taker', 'label': 'taker', 'endpoint': {'httpBaseUrl': base_url + '/remote/taker', 'wsBaseUrl': 'ws://x', 'providerKind': 't3_relay'}},
                            {'environmentId': 'env-xps', 'label': 'xps-grace', 'endpoint': {'httpBaseUrl': base_url + '/remote/xps', 'wsBaseUrl': 'ws://x', 'providerKind': 't3_relay'}},
                            {'environmentId': 'env-mini', 'label': 'mac-mini', 'endpoint': {'httpBaseUrl': base_url + '/remote/mini', 'wsBaseUrl': 'ws://x', 'providerKind': 't3_relay'}},
                        ]
                    })
                    return
                if parsed.path == '/v1/mobile/agent-activity':
                    self.send_json(200, {
                        'aggregate': {
                            'title': 'Agents',
                            'subtitle': 'Live',
                            'activeCount': 2,
                            'updatedAt': '2026-11-27T18:20:00Z',
                            'activities': [
                                {
                                    'environmentId': 'env-xps',
                                    'threadId': 'thr-xps-1',
                                    'projectTitle': 'omabot',
                                    'threadTitle': 'Diagnose Device Speaker Failure',
                                    'modelTitle': 'codex',
                                    'phase': 'waiting_for_approval',
                                    'status': 'Waiting',
                                    'updatedAt': '2026-11-27T18:20:00Z',
                                    'deepLink': 't3://x',
                                },
                                {
                                    'environmentId': 'env-mini',
                                    'threadId': 'thr-stale-offline',
                                    'projectTitle': 'old',
                                    'threadTitle': 'Offline Device Thread',
                                    'modelTitle': 'claude',
                                    'phase': 'running',
                                    'status': 'Working',
                                    'updatedAt': '2026-11-27T18:00:00Z',
                                    'deepLink': 't3://y',
                                },
                            ],
                        }
                    })
                    return
                if parsed.path == '/remote/taker/api/orchestration/shell':
                    test_case.assertEqual(self.headers.get('x-t3-orchestration-protocol'), '2')
                    self.send_json(200, {
                        'projects': [{'id': 'p-taker', 'title': 'omarchy', 'workspaceRoot': '/home/sbull/omarchy', 'deletedAt': None}],
                        'threads': [
                            {
                                'id': 'thr-taker-1',
                                'projectId': 'p-taker',
                                'title': 'Animated Omarchy Setup Wizard',
                                'providerInstanceId': 'claude',
                                'branch': 'wizard',
                                'worktreePath': None,
                                'status': 'running',
                                'activityRunStatus': 'running',
                                'pendingRuntimeRequest': None,
                                'pendingBackgroundTasks': [],
                                'latestVisibleMessage': {'id': 'm1', 'role': 'user', 'text': 'PRIVATE_PROMPT', 'updatedAt': '2026-11-27T18:19:00Z'},
                                'updatedAt': '2026-11-27T18:19:00Z',
                                'latestRunCompletedAt': None,
                                'lastVisitedAt': None,
                                'settledAt': None,
                                'settledOverride': None,
                                'deletedAt': None,
                                'archivedAt': None,
                            }
                        ],
                    })
                    return
                self.send_json(404, {'error': 'not_found'})

            def do_POST(self):
                length = int(self.headers.get('Content-Length') or 0)
                _ = self.rfile.read(length) if length else b''
                parsed = urllib.parse.urlparse(self.path)
                if parsed.path == '/v1/client/dpop-token':
                    self.send_json(200, {'access_token': 'relay-dpop-tok', 'token_type': 'DPoP', 'expires_in': 300})
                    return
                if parsed.path == '/v1/environments/env-taker/status':
                    self.send_json(200, {
                        'environmentId': 'env-taker',
                        'status': 'online',
                        'checkedAt': '2026-11-27T18:20:00Z',
                        'descriptor': {'label': 'taker', 'platform': {'machine': 'x86_64'}},
                    })
                    return
                if parsed.path == '/v1/environments/env-xps/status':
                    self.send_json(200, {
                        'environmentId': 'env-xps',
                        'status': 'online',
                        'checkedAt': '2026-11-27T18:20:00Z',
                        'descriptor': {'label': 'xps-grace', 'platform': {'machine': 'aarch64'}},
                    })
                    return
                if parsed.path == '/v1/environments/env-mini/status':
                    self.send_json(200, {
                        'environmentId': 'env-mini',
                        'status': 'offline',
                        'checkedAt': '2026-11-27T18:20:00Z',
                        'offlineReason': 'tunnel_released',
                    })
                    return
                if parsed.path == '/v1/environments/env-taker/connect':
                    self.send_json(200, {
                        'environmentId': 'env-taker',
                        'endpoint': {'httpBaseUrl': base_url + '/remote/taker', 'wsBaseUrl': 'ws://x', 'providerKind': 't3_relay'},
                        'credential': 'boot-taker',
                        'expiresAt': '2026-11-27T19:00:00Z',
                    })
                    return
                if parsed.path == '/v1/environments/env-xps/connect':
                    self.send_json(200, {
                        'environmentId': 'env-xps',
                        'endpoint': {'httpBaseUrl': base_url + '/remote/xps', 'wsBaseUrl': 'ws://x', 'providerKind': 't3_relay'},
                        'credential': 'boot-xps',
                        'expiresAt': '2026-11-27T19:00:00Z',
                    })
                    return
                if parsed.path == '/remote/taker/oauth/token':
                    self.send_json(200, {'access_token': 'env-tok-taker', 'token_type': 'DPoP', 'expires_in': 600})
                    return
                if parsed.path == '/remote/xps/oauth/token':
                    self.send_json(403, {'error': 'device_approval_required', 'approvalCode': 'ABCD-1234'})
                    return
                self.send_json(404, {'error': 'not_found'})

        server = ThreadingHTTPServer(('127.0.0.1', 0), MockRelayHandler)
        port = server.server_address[1]
        base_url = f'http://127.0.0.1:{port}'
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.shutdown)
        self.addCleanup(server.server_close)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            t3_home = root / 't3'
            userdata = t3_home / 'userdata'
            userdata.mkdir(parents=True)
            (userdata / 'environment-id').write_text('env-saber\n')
            (userdata / 'server-runtime.json').write_text(
                json.dumps({'version': 1, 'pid': os.getpid(), 'origin': f'http://127.0.0.1:{port}'})
            )
            create_v2_sqlite(
                userdata / 'statev2.sqlite',
                [
                    {
                        'id': 'thr-saber-1',
                        'title': 'Fleet Support PR',
                        'provider': 'claude',
                        'run_status': 'completed',
                        'completed_at': '2026-11-27T18:18:00Z',
                        'updated_at': '2026-11-27T18:18:00Z',
                    }
                ],
            )
            state_dir = root / 'state'
            oauth = self.mod.OAuthStore(state_dir, issuer=base_url, allow_insecure_issuer=True)
            oauth.save({
                'schema_version': 1,
                'issuer': base_url,
                'client_id': 'test',
                'access_token': 'clerk-tok',
                'refresh_token': 'ref-tok',
                'expires_at': time.time() + 3600,
                'updated_at_ms': self.mod.now_ms(),
            })
            dpop = self.mod.DpopKey(state_dir / 'dpop-key.pem')
            collector = self.mod.FleetCollector(
                t3_home=t3_home,
                oauth_store=oauth,
                dpop_key=dpop,
                relay_url=base_url,
                allow_insecure_relay=True,
                expected_local_comm=None,
            )
            collector.poll_remote_once(force=True)
            snapshot = collector.build_snapshot()
            self.assertIsNotNone(snapshot)
            self.assertEqual(snapshot['schema_version'], 1)
            self.assertEqual(snapshot['environment_id'], 'env-saber')

            devices = {d['id']: d for d in snapshot['devices']}
            self.assertEqual(set(devices.keys()), {'env-saber', 'env-taker', 'env-xps', 'env-mini'})
            self.assertEqual(devices['env-saber']['state'], 'online')
            self.assertTrue(devices['env-saber']['local'])
            self.assertEqual(devices['env-taker']['state'], 'online')
            self.assertEqual(devices['env-taker']['machine'], 'x86_64')
            self.assertEqual(devices['env-xps']['state'], 'online')
            self.assertEqual(devices['env-xps']['machine'], 'aarch64')
            self.assertEqual(devices['env-mini']['state'], 'offline')
            # Online devices come before offline, local first
            self.assertEqual([d['id'] for d in snapshot['devices']], ['env-saber', 'env-taker', 'env-xps', 'env-mini'])

            threads = {t['thread_id']: t for t in snapshot['threads']}
            self.assertEqual(set(threads.keys()), {'thr-saber-1', 'thr-taker-1', 'thr-xps-1'})
            self.assertEqual(threads['thr-saber-1']['device_label'], 'saber')
            self.assertTrue(threads['thr-saber-1']['device_local'])
            self.assertEqual(threads['thr-taker-1']['device_label'], 'taker')
            self.assertEqual(threads['thr-taker-1']['status'], 'working')
            self.assertEqual(threads['thr-xps-1']['device_label'], 'xps-grace')
            self.assertEqual(threads['thr-xps-1']['status'], 'waiting_for_approval')
            self.assertTrue(threads['thr-xps-1']['pending_input'])
            # Offline device's stale activity is suppressed, and private prompts never leak
            serialized = json.dumps(snapshot)
            self.assertNotIn('thr-stale-offline', serialized)
            self.assertNotIn('PRIVATE_PROMPT', serialized)
            self.assertNotIn('NEVER_LEAK_THIS_PROMPT', serialized)
            # Diagnostics record Tier 1 approval fallback for xps-grace
            diag = collector.diagnostics()
            self.assertEqual(diag['tier1_shell_environments'], ['env-taker'])
            self.assertEqual(diag['tier1_approval_pending'], {'env-xps': 'ABCD-1234'})

            # Logout clears remote devices and remote threads immediately
            oauth.delete()
            collector.poll_remote_once(force=True)
            after_logout = collector.build_snapshot()
            self.assertEqual([d['id'] for d in after_logout['devices']], ['env-saber'])
            self.assertEqual([t['thread_id'] for t in after_logout['threads']], ['thr-saber-1'])

            # Stopped local server reports local device as offline
            (userdata / 'server-runtime.json').unlink()
            stopped = collector.build_snapshot()
            self.assertEqual(stopped['devices'][0]['state'], 'offline')
            self.assertEqual(stopped['threads'], [])

    def test_http_request_refuses_redirects_and_rejects_insecure_urls(self):
        class RedirectHandler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                pass

            def do_GET(self):
                self.send_response(302)
                self.send_header('Location', 'http://127.0.0.1:1/steal')
                self.end_headers()

        server = ThreadingHTTPServer(('127.0.0.1', 0), RedirectHandler)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.shutdown)
        self.addCleanup(server.server_close)

        with self.assertRaises(self.mod.HttpError) as ctx:
            self.mod.http_request('GET', f'http://127.0.0.1:{port}/start')
        self.assertEqual(ctx.exception.status, 302)
        self.assertFalse(self.mod.is_allowed_remote_url('http://relay.t3.codes'))
        self.assertFalse(self.mod.is_allowed_remote_url('https://user:pass@relay.t3.codes'))
        self.assertFalse(self.mod.is_allowed_remote_url('https://relay.t3.codes?q=1'))
        self.assertTrue(self.mod.is_allowed_remote_url('https://relay.t3.codes/oauth?user_code=1234', allow_query=True))

    def test_oauth_token_fallback_probes_well_known_and_uses_paired_remote_tokens(self):
        class OAuthRelayHandler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                pass

            def send_json(self, code: int, body: dict):
                raw = json.dumps(body).encode('utf-8')
                self.send_response(code)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                if parsed.path == '/v1/environments':
                    self.send_json(200, {
                        'environments': [
                            {'environmentId': 'env-saber', 'label': 'saber', 'endpoint': {'httpBaseUrl': base_url + '/saber'}},
                            {'environmentId': 'env-taker', 'label': 'taker', 'endpoint': {'httpBaseUrl': base_url + '/taker'}},
                            {'environmentId': 'env-xps16', 'label': 'xps16', 'endpoint': {'httpBaseUrl': base_url + '/xps16'}},
                        ]
                    })
                    return
                if parsed.path == '/taker/.well-known/t3/environment':
                    self.send_json(200, {'environmentId': 'env-taker', 'label': 'taker', 'platform': {'machine': 'laptop'}})
                    return
                if parsed.path == '/xps16/.well-known/t3/environment':
                    self.send_json(530, {'error': 'tunnel_offline'})
                    return
                if parsed.path == '/taker/api/orchestration/shell':
                    if self.headers.get('Authorization') != 'Bearer ro-taker-tok':
                        self.send_json(401, {'error': 'unauthorized'})
                        return
                    self.send_json(200, {
                        'projects': [{'id': 'p1', 'title': 'omarchy', 'workspaceRoot': '/home/sbull/omarchy', 'deletedAt': None}],
                        'threads': [{
                            'id': 'thr-taker-live',
                            'projectId': 'p1',
                            'title': 'Remote Wizard Thread',
                            'providerInstanceId': 'codex',
                            'branch': 'main',
                            'worktreePath': None,
                            'status': 'running',
                            'activityRunStatus': 'running',
                            'pendingRuntimeRequest': None,
                            'pendingBackgroundTasks': [],
                            'updatedAt': '2026-11-27T19:30:00Z',
                            'latestRunCompletedAt': None,
                            'lastVisitedAt': None,
                            'settledAt': None,
                            'settledOverride': None,
                            'deletedAt': None,
                            'archivedAt': None,
                        }],
                    })
                    return
                self.send_json(404, {'error': 'not_found'})

            def do_POST(self):
                length = int(self.headers.get('Content-Length') or 0)
                _ = self.rfile.read(length) if length else b''
                if self.path == '/v1/client/dpop-token':
                    self.send_json(401, {'code': 'auth_invalid', 'reason': 'invalid_bearer'})
                    return
                self.send_json(404, {'error': 'not_found'})

        server = ThreadingHTTPServer(('127.0.0.1', 0), OAuthRelayHandler)
        port = server.server_address[1]
        base_url = f'http://127.0.0.1:{port}'
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.shutdown)
        self.addCleanup(server.server_close)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            t3_home = root / 't3'
            userdata = t3_home / 'userdata'
            userdata.mkdir(parents=True)
            (userdata / 'environment-id').write_text('env-saber\n')
            (userdata / 'server-runtime.json').write_text(
                json.dumps({'version': 1, 'pid': os.getpid(), 'origin': f'http://127.0.0.1:{port}'})
            )
            state_dir = root / 'state'
            oauth = self.mod.OAuthStore(state_dir, issuer=base_url, allow_insecure_issuer=True)
            oauth.save({
                'schema_version': 1,
                'issuer': base_url,
                'client_id': 'test',
                'access_token': 'clerk-oauth-tok',
                'refresh_token': 'ref',
                'expires_at': time.time() + 3600,
                'updated_at_ms': self.mod.now_ms(),
            })
            token_file = root / 'tok.txt'
            token_file.write_text('ro-taker-tok\n')
            env_id, label, count = self.mod.pair_remote_environment(
                'taker',
                state_dir=state_dir,
                relay_url=base_url,
                issuer=base_url,
                client_id='test',
                token_file=token_file,
                allow_insecure=True,
            )
            self.assertEqual((env_id, label, count), ('env-taker', 'taker', 1))

            dpop = self.mod.DpopKey(state_dir / 'dpop-key.pem')
            collector = self.mod.FleetCollector(
                t3_home=t3_home,
                oauth_store=oauth,
                dpop_key=dpop,
                relay_url=base_url,
                allow_insecure_relay=True,
                expected_local_comm=None,
            )
            collector.poll_remote_once(force=True)
            snapshot = collector.build_snapshot()
            devices = {d['id']: d for d in snapshot['devices']}
            self.assertEqual(devices['env-saber']['state'], 'online')
            self.assertEqual(devices['env-taker']['state'], 'online')
            self.assertEqual(devices['env-taker']['machine'], 'laptop')
            self.assertEqual(devices['env-xps16']['state'], 'offline')
            threads = {t['thread_id']: t for t in snapshot['threads']}
            self.assertIn('thr-taker-live', threads)
            self.assertEqual(threads['thr-taker-live']['device_label'], 'taker')
            self.assertFalse(threads['thr-taker-live']['device_local'])

    def test_collect_cliproxy_usage_aggregates_multi_account_quotas_without_secrets(self):
        with tempfile.TemporaryDirectory() as tmp:
            backend = Path(tmp) / 'backend.py'
            today_utc = time.strftime('%Y-%m-%d', time.gmtime())
            backend.write_text(
                '#!/usr/bin/python3\n'
                'import json, sys\n'
                'print(json.dumps({"type":"state","configured":True,"url":"https://proxy.example"}), flush=True)\n'
                'for line in sys.stdin:\n'
                '    msg = json.loads(line)\n'
                '    if msg["op"] == "refresh":\n'
                '        print(json.dumps({"type":"snapshot","accounts":[\n'
                '            {"id":"a1","provider":"claude","status":"active","quotaSupported":True,"email":"secret@example.com"},\n'
                '            {"id":"a2","provider":"claude","status":"active","quotaSupported":True,"email":"secret2@example.com"},\n'
                '            {"id":"m1","provider":"meta","status":"active","quotaSupported":True}\n'
                f'        ],"usageHistory":{{"buckets":[{{"date":"{today_utc}","provider":"claude","tokenMetrics":{{"total":{{"value":420000}}}}}}]}}}}), flush=True)\n'
                '    elif msg["op"] == "quota":\n'
                '        assert msg.get("allowKeyIssue") is False\n'
                '        used = 10.0 if msg["id"] == "a1" else 20.0\n'
                '        print(json.dumps({"type":"quota","plan":"max","windows":[{"label":"Weekly","usedPercent":used,"resetAt":"2026-12-01T14:00:00Z"}]}), flush=True)\n'
            )
            result = self.mod.collect_cliproxy_usage(backend_path=backend)
            self.assertIsNotNone(result)
            self.assertEqual(result['schema_version'], 1)
            self.assertEqual(len(result['providers']), 1)
            claude = result['providers'][0]
            self.assertEqual(claude['id'], 'claude')
            self.assertEqual(claude['plan'], 'Max')
            self.assertEqual(claude['account_count'], 2)
            self.assertAlmostEqual(claude['primary']['utilization'], 0.15, places=3)
            self.assertEqual(claude['today_tokens'], 420000)
            self.assertNotIn('secret@example.com', json.dumps(result))
