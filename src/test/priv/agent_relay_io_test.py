"""Real relay filesystem-failure and diagnostic-log bounds."""
import json
import os
import signal
import socket
import unittest

import agent_relay_test as harness


class RelayIOTest(unittest.TestCase):
    setUp = harness.RelayTest.setUp
    start = harness.RelayTest.start
    connect = harness.RelayTest.connect
    send = harness.RelayTest.send
    read = harness.RelayTest.read
    wait = harness.RelayTest.wait
    assert_group_dead = harness.RelayTest.assert_group_dead

    def tearDown(self):
        for client in self.clients:
            client.close()
        manifest = self.directory / 'relay.json'
        if manifest.exists():
            metadata = json.loads(manifest.read_text())
            for identifier, grouped in ((metadata['pgid'], True), (metadata['relay_pid'], False)):
                try:
                    (os.killpg if grouped else os.kill)(identifier, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.temp.cleanup()

    def assert_io_failure_stops(self, client, stream, metadata):
        client.settimeout(2)
        received = []
        try:
            while line := stream.readline():
                received.append(json.loads(line))
        except socket.timeout:
            self.fail('I/O failure left controller connected')
        self.assertTrue(any(frame.get('error') == 'io_failure' for frame in received), received)
        self.wait(lambda: not (self.directory / 'ctl.sock').exists(), timeout=3)
        self.assert_group_dead(metadata['pgid'])

    def test_full_journal_disconnects_controller_and_stops_provider(self):
        (self.directory / 'out.journal').symlink_to('/dev/full')
        self.start()
        client, stream, metadata = self.connect(1)
        self.send(client, op='stdin', line='cannot journal\n')
        self.assert_io_failure_stops(client, stream, metadata)

    def test_manifest_write_failure_disconnects_controller_and_stops_provider(self):
        self.start()
        client, stream, metadata = self.connect(1)
        (self.directory / 'relay.json.tmp').mkdir()
        self.send(client, op='stdin', line='cannot persist\n')
        self.assert_io_failure_stops(client, stream, metadata)

    def test_stderr_log_remains_bounded_and_retains_latest_output(self):
        cap = 64 * 1024 * 1024
        self.start("import os\nfor _ in range(65): os.write(2, b'x' * 1048575 + b'\\n')\nos.write(2, b'latest\\n')",
                   journal_cap=cap * 2)
        self.wait(lambda: json.loads((self.directory / 'relay.json').read_text())['exit_status'] == 0)
        log = self.directory / 'err.log'
        self.assertLessEqual(log.stat().st_size, cap)
        with log.open('rb') as stream:
            stream.seek(-7, 2)
            self.assertEqual(stream.read(), b'latest\n')


if __name__ == '__main__':
    unittest.main()
