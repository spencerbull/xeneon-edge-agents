#!/usr/bin/python3

from __future__ import annotations

import json
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CHECKER = REPO_ROOT / "scripts" / "check-herdr-compatibility.py"


class HerdrCompatibilityTests(unittest.TestCase):
    def run_checker(self, protocol: int) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            socket_path = root / "herdr.sock"
            ready = threading.Event()

            def serve() -> None:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                    server.bind(str(socket_path))
                    server.listen(1)
                    ready.set()
                    connection, _ = server.accept()
                    with connection:
                        request = json.loads(connection.makefile().readline())
                        response = {
                            "id": request["id"],
                            "result": {
                                "version": "0.7.5",
                                "protocol": protocol,
                            },
                        }
                        connection.sendall(json.dumps(response).encode() + b"\n")

            server_thread = threading.Thread(target=serve, daemon=True)
            server_thread.start()
            self.assertTrue(ready.wait(timeout=2))

            herdr = root / "herdr"
            session_list = {
                "sessions": [
                    {
                        "name": "test",
                        "running": True,
                        "socket_path": str(socket_path),
                    }
                ]
            }
            herdr.write_text(
                "#!/usr/bin/bash\n"
                'if [[ "$1" == "--version" ]]; then\n'
                "  printf 'herdr 0.7.5\\n'\n"
                "else\n"
                f"  printf '%s\\n' '{json.dumps(session_list)}'\n"
                "fi\n"
            )
            herdr.chmod(0o755)

            result = subprocess.run(
                [str(CHECKER), str(herdr)],
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
            server_thread.join(timeout=2)
            return result

    def test_accepts_stable_and_guarded_action_protocols(self) -> None:
        for protocol in (17, 18):
            with self.subTest(protocol=protocol):
                result = self.run_checker(protocol)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"protocol-{protocol}", result.stdout)

    def test_rejects_unknown_protocol(self) -> None:
        result = self.run_checker(19)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported protocol", result.stderr)


if __name__ == "__main__":
    unittest.main()
