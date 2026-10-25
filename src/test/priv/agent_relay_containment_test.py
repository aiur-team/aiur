"""A tool command that leaves the provider's session still dies with the relay (#4730)."""
import json
import os
from pathlib import Path
import signal
import time
import unittest

import agent_relay_test as harness

# The shape of the incident: backgrounded, setsid, then `timeout` takes its own
# process group, and the launching shell exits so the loop is orphaned. It
# sleeps instead of spinning: tests never generate real CPU load.
DETACH = ("(setsid timeout 30 sh -c 'echo $$ > loop.pid; while :; do sleep 0.2; done' "
          "</dev/null >/dev/null 2>&1 &)")
PROVIDER = ("import subprocess,sys\n"
            f"subprocess.run(['bash', '-c', {DETACH!r}])\n"
            "print('ready', flush=True)\n"
            "sys.stdin.readline()\n")

# A tool shell still running at the turn end, in its own session the way
# headless Claude and Codex run tool commands, beside MCP servers: Claude's in
# the provider group, Codex's in a group of its own within the provider session.
LIVE_SHELL = ("import subprocess,sys\n"
              "subprocess.Popen(['setsid', 'sh', '-c', "
              "\"timeout 30 sh -c 'echo $$ > loop.pid; while :; do sleep 0.2; done'\"])\n"
              "servers = [subprocess.Popen(['sleep', '30']), subprocess.Popen(['sleep', '30'], process_group=0)]\n"
              "open('server.pid', 'w').write(' '.join(str(server.pid) for server in servers))\n"
              "print('ready', flush=True)\n"
              "sys.stdin.readline()\n")

# The provider's own short-lived children, like a shell's `$(...)`: the reap
# must spare one forked while it runs, or the provider loses a reply.
CHURN = ("import subprocess,sys,threading\n"
         "def churn():\n"
         "    while True:\n"
         "        if subprocess.run(['true']).returncode < 0: open('killed', 'w').close()\n"
         "threading.Thread(target=churn, daemon=True).start()\n"
         "print('ready', flush=True)\n"
         "sys.stdin.readline()\n")


def state(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    except FileNotFoundError:
        return None


def alive(pid):
    fields = state(pid)
    return fields is not None and fields[0] != 'Z'


class RelayContainmentTest(unittest.TestCase):
    setUp = harness.RelayTest.setUp
    start = harness.RelayTest.start
    connect = harness.RelayTest.connect
    send = harness.RelayTest.send
    read = harness.RelayTest.read
    wait = harness.RelayTest.wait

    def tearDown(self):
        # Without the fix the loop survives the relay; never leave it behind.
        for pid in (getattr(self, 'loop', None), *getattr(self, 'servers', ())):
            if pid and alive(pid):
                os.kill(pid, signal.SIGKILL)
        harness.RelayTest.tearDown(self)

    def start_detached_loop(self):
        self.start(PROVIDER)
        client, stream, hello = self.connect(1)
        self.assertEqual(self.read(stream)['line'], 'ready')
        pid_file = self.directory / 'loop.pid'
        self.wait(lambda: pid_file.exists() and pid_file.read_text().strip())
        self.loop = int(pid_file.read_text())
        self.assertTrue(alive(self.loop))
        timeout_pid = int(state(self.loop)[1])
        self.assertNotEqual(int(state(self.loop)[2]), hello['pgid'], 'loop must have left the provider group')
        # Its launching shell is gone, so it was adopted by the relay, not init.
        self.wait(lambda: int(state(timeout_pid)[1]) == hello['relay_pid'])
        return client

    def test_detached_loop_dies_when_provider_command_ends(self):
        client = self.start_detached_loop()
        self.send(client, op='stdin', line='done\n')
        self.wait(lambda: json.loads((self.directory / 'relay.json').read_text())['exit_status'] == 0)
        self.wait(lambda: not alive(self.loop))

    def test_detached_loop_dies_when_relay_is_stopped(self):
        client = self.start_detached_loop()
        self.send(client, op='stop', grace_ms=1000)
        self.wait(lambda: not (self.directory / 'ctl.sock').exists())
        self.assertFalse(alive(self.loop))

    def test_turn_reap_kills_a_loop_under_a_live_tool_shell_and_spares_the_provider_session(self):
        self.start(LIVE_SHELL)
        client, stream, hello = self.connect(1)
        self.assertEqual(self.read(stream)['line'], 'ready')
        loop_file = self.directory / 'loop.pid'
        self.wait(lambda: loop_file.exists() and loop_file.read_text().strip())
        self.loop = int(loop_file.read_text())
        self.servers = [int(pid) for pid in (self.directory / 'server.pid').read_text().split()]
        self.assertTrue(alive(self.loop))
        self.send(client, op='reap')
        self.wait(lambda: not alive(self.loop))
        for server in self.servers:
            self.assertTrue(alive(server))
        self.assertTrue(alive(hello['provider_pid']))

    def test_turn_reap_spares_a_child_the_provider_forks_meanwhile(self):
        self.start(CHURN)
        client, stream, hello = self.connect(1)
        self.assertEqual(self.read(stream)['line'], 'ready')
        for _ in range(200):
            self.send(client, op='reap')
        time.sleep(1)
        self.assertFalse((self.directory / 'killed').exists())


if __name__ == '__main__':
    unittest.main()
