import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).parents[1] / 'config/bin/xeneon-t3-status'


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
        helper = subprocess.Popen(['/usr/bin/python3', str(HELPER), '--t3-bin', str(child),
                                   '--t3-home', str(root), '--output', str(output)],
                                  stderr=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                  env={**os.environ, 'XDG_RUNTIME_DIR': str(root)}, start_new_session=True)
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
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "print(os.getpid(), file=sys.stderr, flush=True)\n"
            "while True: signal.pause()\n")
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
