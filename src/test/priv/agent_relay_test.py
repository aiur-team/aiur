"""Exercise the real detached relay through its Unix socket."""
import base64
import json
import importlib.util
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "priv" / "agent_relay.py"


class RelayTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="relay-")
        self.directory = Path(self.temp.name)
        self.clients = []

    def tearDown(self):
        for client in self.clients:
            client.close()
        manifest = self.directory / "relay.json"
        if manifest.exists():
            pid = json.loads(manifest.read_text())["relay_pid"]
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            self.wait(lambda: not (self.directory / "ctl.sock").exists())
        self.temp.cleanup()

    def wait(self, predicate, timeout=5):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(0.02)
        self.fail("relay condition timed out")

    def start(self, code=None, **options):
        code = code or "import sys\nfor line in sys.stdin: print(line.rstrip('\\n'), flush=True)"
        spec = {"argv": [sys.executable, "-u", "-c", code], "cwd": str(self.directory),
                "env": {}, "backend": "fake", "relay_id": "test.1.nonce", "spawn_nonce": "nonce",
                "orphan_timeout_seconds": 60, **options}
        path = self.directory / "spec.json"
        path.write_text(json.dumps(spec))
        completed = subprocess.run([sys.executable, str(SCRIPT), "--directory", str(self.directory),
                                    "--spec", str(path)], capture_output=True, timeout=5)
        self.assertEqual(completed.returncode, 0, completed.stderr.decode())
        self.wait(lambda: (self.directory / "ctl.sock").exists())
        self.assertFalse(path.exists())
        self.assertEqual((self.directory.stat().st_mode & 0o777), 0o700)
        self.assertEqual(((self.directory / "ctl.sock").stat().st_mode & 0o777), 0o600)

    def connect(self, generation=None, offset=0):
        client = socket.socket(socket.AF_UNIX)
        client.settimeout(5)
        client.connect(str(self.directory / "ctl.sock"))
        self.clients.append(client)
        stream = client.makefile("rb")
        self.addCleanup(stream.close)
        self.send(client, op="hello")
        hello = self.read(stream)
        self.assertEqual(hello["op"], "hello")
        if generation is not None:
            self.send(client, op="attach", generation=generation, from_offset=offset)
            self.assertEqual(self.read(stream)["op"], "attached")
        return client, stream, hello

    def send(self, client, **message):
        client.sendall((json.dumps(message) + "\n").encode())

    def read(self, stream):
        line = stream.readline()
        self.assertTrue(line, "unexpected controller disconnect")
        return json.loads(line)

    def test_launcher_exit_roundtrip_and_stderr(self):
        self.start("import sys\nfor line in sys.stdin:\n print(line.rstrip('\\n'), flush=True)\n print('diagnostic', file=sys.stderr, flush=True)")
        client, stream, hello = self.connect(1)
        self.assertEqual(hello["spawn_nonce"], "nonce")
        self.send(client, op="stdin", line="hello\n")
        frames = [self.read(stream), self.read(stream)]
        self.assertEqual({f["line"] for f in frames}, {"hello", "diagnostic"})
        self.assertEqual([f["offset"] for f in frames], sorted(f["offset"] for f in frames))
        journal = (self.directory / "out.journal").read_text().splitlines()
        self.assertCountEqual(journal, ["hello", "diagnostic"])
        self.assertFalse((self.directory / "err.log").exists())

    def test_provider_environment_is_exactly_the_scrubbed_spec(self):
        previous = os.environ.get("AIUR_RELAY_SECRET_TEST")
        os.environ["AIUR_RELAY_SECRET_TEST"] = "must-not-leak"
        try:
            self.start("import os\nprint(os.environ.get('AIUR_RELAY_SECRET_TEST', 'scrubbed'), flush=True)")
        finally:
            if previous is None:
                os.environ.pop("AIUR_RELAY_SECRET_TEST")
            else:
                os.environ["AIUR_RELAY_SECRET_TEST"] = previous
        _, stream, _ = self.connect(1)
        self.assertEqual(self.read(stream)["line"], "scrubbed")

    def test_detach_replays_only_unacked_frames(self):
        self.start()
        client, stream, _ = self.connect(1)
        self.send(client, op="stdin", line="one\ntwo\n")
        first, second = self.read(stream), self.read(stream)
        self.send(client, op="ack", offset=first["offset"])
        self.send(client, op="detach")
        self.assertEqual(stream.readline(), b"")
        new_client, new_stream, hello = self.connect(2, first["offset"])
        self.assertEqual(hello["acked_offset"], first["offset"])
        self.assertEqual(self.read(new_stream), second)
        self.send(new_client, op="stdin", line="three\n")
        third = self.read(new_stream)
        self.assertEqual(third["line"], "three")
        self.assertGreater(third["offset"], second["offset"])

    def test_ack_compacts_storage_without_resetting_offsets(self):
        self.start()
        client, stream, _ = self.connect(1)
        self.send(client, op="stdin", line="x" * (1024 * 1024) + "\nretained\n")
        first, second = self.read(stream), self.read(stream)
        self.send(client, op="ack", offset=first["offset"])
        self.send(client, op="hello")
        self.assertEqual(self.read(stream)["acked_offset"], first["offset"])
        self.assertEqual((self.directory / "out.journal").read_bytes(), b"retained\n")
        self.send(client, op="detach")
        self.assertEqual(stream.readline(), b"")
        _, new_stream, _ = self.connect(2, first["offset"])
        self.assertEqual(self.read(new_stream), second)

    def test_generation_fences_and_rejects_stale_controller(self):
        self.start()
        first, first_stream, _ = self.connect(3)
        for generation in (2, 3):
            client, stream, _ = self.connect()
            self.send(client, op="attach", generation=generation, from_offset=0)
            self.assertEqual(self.read(stream)["op"], "error")
        invalid, invalid_stream, _ = self.connect()
        self.send(invalid, op="attach", generation=4, from_offset=1)
        self.assertEqual(self.read(invalid_stream)["op"], "error")
        self.send(first, op="stdin", line="still-owned\n")
        self.assertEqual(self.read(first_stream)["line"], "still-owned")
        second, second_stream, _ = self.connect(4)
        self.assertEqual(first_stream.readline(), b"")
        self.assertEqual(self.read(second_stream)["line"], "still-owned")
        self.send(second, op="stdin", line="fenced\n")
        self.assertEqual(self.read(second_stream)["line"], "fenced")

    def test_exit_while_detached_replays_frames_before_status(self):
        self.start("import time\ntime.sleep(.1)\nprint('last', flush=True)\nraise SystemExit(7)")
        self.wait(lambda: json.loads((self.directory / "relay.json").read_text())["exit_status"] == 7)
        _, stream, _ = self.connect(1)
        self.assertEqual(self.read(stream)["line"], "last")
        self.assertEqual(self.read(stream), {"op": "exit", "status": 7})

    def test_invalid_utf8_is_preserved_as_bytes(self):
        self.start("import os\nos.write(1, b'\\xff\\x00\\n')")
        _, stream, _ = self.connect(1)
        frame = self.read(stream)
        self.assertEqual(base64.b64decode(frame["line_base64"]), b"\xff\x00")
        self.assertEqual(frame["offset"], 3)

    def test_long_frame_is_intact(self):
        self.start()
        client, stream, _ = self.connect(1)
        value = "x" * (1024 * 1024 + 13)
        self.send(client, op="stdin", line=value + "\n")
        frame = self.read(stream)
        self.assertEqual(frame["line"], value)
        self.assertEqual(frame["offset"], len(value) + 1)

    def test_cap_marks_lossy_and_refuses_attach(self):
        self.start("print('x' * 1024, flush=True)\nimport time\ntime.sleep(60)", journal_cap=128)
        self.wait(lambda: json.loads((self.directory / "relay.json").read_text())["lossy"])
        client, stream, hello = self.connect()
        self.assertTrue(hello["lossy"])
        self.send(client, op="attach", generation=1, from_offset=0)
        self.assertEqual(self.read(stream), {"op": "error", "error": "lossy"})
        self.assertLessEqual((self.directory / "out.journal").stat().st_size, 128)

    def test_orphan_timeout_stops_provider_group(self):
        self.start("import subprocess,sys,time\nsubprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])\ntime.sleep(60)", orphan_timeout_seconds=0.2)
        manifest = json.loads((self.directory / "relay.json").read_text())
        self.wait(lambda: not (self.directory / "ctl.sock").exists())
        self.assertIsNotNone(json.loads((self.directory / "relay.json").read_text())["exit_status"])
        self.assert_group_dead(manifest["pgid"])

    def assert_group_dead(self, pgid):
        # Zombies are already stopped; container init may defer reaping them.
        def alive():
            for path in Path('/proc').glob('[0-9]*/stat'):
                try:
                    fields = path.read_text().rsplit(')', 1)[1].split()
                    if int(fields[2]) == pgid and fields[0] != 'Z':
                        return True
                except (FileNotFoundError, ProcessLookupError):
                    pass
            return False
        self.wait(lambda: not alive())

    def test_stop_closes_existing_controller_connection(self):
        self.start()
        client, stream, _ = self.connect(1)
        client.settimeout(2)
        self.send(client, op="stop", grace_ms=10000)
        received = []
        while line := stream.readline():
            received.append(json.loads(line))
        self.assertEqual(received, [{"op": "exit", "status": 143}])

    def test_stop_terminates_provider_and_relay(self):
        self.start("import signal,time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nprint('ready', flush=True)\ntime.sleep(60)")
        client, stream, hello = self.connect(1)
        self.assertEqual(self.read(stream)["line"], "ready")
        self.send(client, op="stop", grace_ms=50)
        self.wait(lambda: not (self.directory / "ctl.sock").exists())
        self.assert_group_dead(hello["pgid"])
        self.assertEqual(json.loads((self.directory / "relay.json").read_text())["exit_status"], 137)

    def test_sweep_removes_old_dead_relays_and_failed_launches(self):
        self.start()
        _, _, live = self.connect(1)
        root = self.directory / "sweep"
        root.mkdir()
        old = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
        cases = {
            "old-dead": {"relay_pid": 999999999, "exit_status": 0, "created_at": old},
            "young-dead": {"relay_pid": 999999999, "exit_status": 0, "created_at": datetime.now(timezone.utc).isoformat()},
            "old-live": {"relay_pid": live["relay_pid"], "exit_status": 0, "created_at": old},
            "no-exit": {"relay_pid": 999999999, "exit_status": None, "created_at": old},
        }
        for name, manifest in cases.items():
            directory = root / name
            directory.mkdir()
            (directory / "relay.json").write_text(json.dumps(manifest))
        for name in ("old-manifestless", "young-manifestless"):
            directory = root / name
            directory.mkdir()
            (directory / "spawn.json").write_text('{"env":{"SECRET":"retained"}}')
            if name == "old-manifestless":
                timestamp = (datetime.now(timezone.utc) - timedelta(days=2)).timestamp()
                os.utime(directory, (timestamp, timestamp))
        (root / "symlink").symlink_to(root / "old-manifestless", target_is_directory=True)
        module_spec = importlib.util.spec_from_file_location("agent_relay", SCRIPT)
        relay = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(relay)
        relay.sweep_dead_relays(root)
        self.assertEqual({path.name for path in root.iterdir()}, {"young-dead", "old-live", "young-manifestless", "symlink"})

    def test_invalid_offsets_cannot_discard_frames(self):
        self.start()
        client, stream, _ = self.connect(1)
        self.send(client, op="stdin", line="retained\n")
        frame = self.read(stream)
        self.send(client, op="ack", offset=frame["offset"] - 1)
        self.assertEqual(self.read(stream)["op"], "error")
        _, _, hello = self.connect()
        self.assertEqual(hello["acked_offset"], 0)


if __name__ == "__main__":
    unittest.main()
