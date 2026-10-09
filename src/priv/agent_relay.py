#!/usr/bin/env python3
"""Detached stdio owner; byte-offset journal and fenced Unix-socket controller."""
import argparse
import base64
import asyncio
from collections import deque
from datetime import datetime, timedelta, timezone
import json
import math
import os
from pathlib import Path
import signal
import shutil
import time

PROTOCOL = 1
CAP = 64 * 1024 * 1024


class Relay:
    def __init__(self, directory, spec):
        self.directory, self.spec = directory, spec
        self.frames = deque()
        self.end = self.acked = self.generation = 0
        self.lossy = False
        self.controller = None
        self.clients = set()
        self.disconnected_at = time.monotonic()
        self.exit_status = None
        self.stopping = False
        self.failed = False
        self.finished = asyncio.Event()
        self.journal = open(directory / 'out.journal', 'wb', buffering=0)
        self.stderr = open(directory / 'err.log', 'ab', buffering=0)
        self.cap = spec.get('journal_cap', CAP)
        self.retained_base = 0
        self.manifest = {}

    def snapshot(self):
        return {**self.manifest, 'generation': self.generation, 'journal_end': self.end,
                'acked_offset': self.acked, 'lossy': self.lossy, 'exit_status': self.exit_status}

    def persist(self):
        temporary = self.directory / 'relay.json.tmp'
        temporary.write_text(json.dumps(self.snapshot()) + '\n')
        temporary.replace(self.directory / 'relay.json')

    def message(self, writer, op, **values):
        writer.write((json.dumps({'op': op, **values}) + '\n').encode())

    def disconnect(self, writer):
        writer.close()
        if self.controller is not None and self.controller[0] is writer:
            self.controller[2].set()
            self.controller = None
            self.disconnected_at = time.monotonic()

    def valid_offset(self, offset):
        return (type(offset) is int and self.acked <= offset <= self.end and
                (offset == self.acked or any(end == offset for end, _ in self.frames)))

    async def receive(self, reader, writer):
        self.clients.add(writer)
        try:
            while line := await reader.readline():
                try:
                    request = json.loads(line)
                    await self.command(writer, request)
                except (ValueError, KeyError, TypeError) as error:
                    self.message(writer, 'error', error=str(error))
                await writer.drain()
        except (ConnectionError, asyncio.LimitOverrunError, ValueError):
            pass
        except OSError:
            self.fail_io()
        finally:
            self.clients.discard(writer)
            self.disconnect(writer)

    async def command(self, writer, request):
        if not isinstance(request, dict):
            raise ValueError('expected object')
        op = request.get('op')
        if op == 'hello':
            self.message(writer, 'hello', **self.snapshot())
        elif op == 'attach':
            generation, offset = request['generation'], request['from_offset']
            if type(generation) is not int or generation <= self.generation:
                raise ValueError('stale_generation')
            if self.lossy:
                raise ValueError('lossy')
            if not self.valid_offset(offset):
                raise ValueError('invalid_offset')
            if self.controller:
                self.disconnect(self.controller[0])
            self.generation = generation
            self.controller = [writer, offset, asyncio.Event()]
            self.persist()
            self.message(writer, 'attached', generation=generation)
            asyncio.create_task(self.forward(self.controller))
        elif self.controller is None or self.controller[0] is not writer:
            raise ValueError('not_controller')
        elif op == 'stdin':
            line = request['line']
            if not isinstance(line, str):
                raise ValueError('invalid_line')
            if self.provider.returncode is not None:
                raise ValueError('provider_exited')
            self.provider.stdin.write(line.encode())
            await self.provider.stdin.drain()
        elif op == 'ack':
            offset = request['offset']
            if not self.valid_offset(offset) or offset > self.controller[1]:
                raise ValueError('invalid_offset')
            self.acked = offset
            while self.frames and self.frames[0][0] <= offset:
                self.frames.popleft()
            if self.acked - self.retained_base >= min(1024 * 1024, self.cap):
                self.rotate()
            self.persist()
        elif op == 'detach':
            self.disconnect(writer)
        elif op == 'signal':
            name = request['name']
            if name not in ('TERM', 'KILL', 'INT', 'HUP'):
                raise ValueError('invalid_signal')
            self.signal_group(getattr(signal, 'SIG' + name))
        elif op == 'stop':
            grace = request.get('grace_ms', 10000)
            if type(grace) is not int or not 0 <= grace <= 60000:
                raise ValueError('invalid_grace')
            asyncio.create_task(self.stop(grace / 1000))
        else:
            raise ValueError('unknown_operation')

    def rotate(self):
        temporary = self.directory / 'out.journal.tmp'
        with open(temporary, 'wb') as output:
            for _, raw in self.frames:
                output.write(raw)
            output.flush()
            os.fsync(output.fileno())
        self.journal.close()
        temporary.replace(self.directory / 'out.journal')
        self.journal = open(self.directory / 'out.journal', 'ab', buffering=0)
        self.retained_base = self.acked

    def fail_io(self):
        if self.failed:
            return
        self.failed = self.lossy = True
        if self.controller:
            writer = self.controller[0]
            try:
                self.message(writer, 'error', error='io_failure')
            except ConnectionError:
                pass
            finally:
                self.disconnect(writer)
        self.signal_group(signal.SIGKILL)
        asyncio.create_task(self.stop(0))

    async def output(self, stream, diagnostic=False):
        pending = bytearray()
        try:
            while data := await stream.read(65536):
                if self.failed:
                    continue
                if diagnostic:
                    if self.stderr.tell() + len(data) > CAP:
                        self.stderr.seek(0)
                        self.stderr.truncate()
                    self.stderr.write(data)
                if self.lossy:
                    continue
                pending.extend(data)
                while (newline := pending.find(b'\n')) >= 0:
                    raw = bytes(pending[:newline + 1])
                    del pending[:newline + 1]
                    await self.append(raw)
                if self.end - self.acked + len(pending) > self.cap:
                    self.mark_lossy()
                    pending.clear()
            if pending and not self.lossy:
                await self.append(bytes(pending))
        except OSError:
            self.fail_io()
            # Drain after killing so inherited pipes cannot keep Process.wait pending.
            while await stream.read(65536):
                pass

    def mark_lossy(self):
        self.lossy = True
        self.persist()
        if self.controller:
            self.message(self.controller[0], 'error', error='lossy')
            self.disconnect(self.controller[0])

    async def append(self, raw):
        if self.lossy:
            return
        if self.end - self.acked + len(raw) > self.cap:
            self.mark_lossy()
            return
        self.journal.write(raw)
        self.end += len(raw)
        self.frames.append((self.end, raw))
        if self.controller:
            self.controller[2].set()
        self.persist()

    async def forward(self, controller):
        writer, _, ready = controller
        delivered_exit = False
        try:
            while self.controller is controller:
                ready.clear()
                for end, raw in list(self.frames):
                    if self.controller is not controller:
                        return
                    if end > controller[1]:
                        payload = raw.removesuffix(b'\n')
                        try:
                            values = {'line': payload.decode('utf-8')}
                        except UnicodeDecodeError:
                            values = {'line': payload.decode('utf-8', errors='replace'),
                                      'line_base64': base64.b64encode(payload).decode('ascii')}
                        self.message(writer, 'frame', offset=end, **values)
                        controller[1] = end
                        await asyncio.wait_for(writer.drain(), timeout=1)
                if self.exit_status is not None and not delivered_exit:
                    self.message(writer, 'exit', status=self.exit_status)
                    await writer.drain()
                    delivered_exit = True
                await ready.wait()
        except (ConnectionError, asyncio.TimeoutError):
            self.disconnect(writer)

    def signal_group(self, sig):
        # A retained exited provider's PID may have been recycled before stop.
        try:
            stat = Path(f'/proc/{self.provider.pid}/stat').read_text().rsplit(')', 1)[1].split()
            if self.provider_start is None or stat[19] != self.provider_start:
                return
        except FileNotFoundError:
            pass
        try:
            os.killpg(self.provider.pid, sig)
        except ProcessLookupError:
            pass

    async def stop(self, grace=10):
        if self.stopping:
            return
        self.stopping = True
        self.signal_group(signal.SIGTERM)
        try:
            await asyncio.wait_for(asyncio.shield(self.provider.wait()), timeout=grace)
        except asyncio.TimeoutError:
            pass
        # Descendants may survive their session leader; always finish group cleanup.
        self.signal_group(signal.SIGKILL)
        await self.provider.wait()
        await asyncio.gather(*self.readers, return_exceptions=True)
        status = self.provider.returncode
        self.exit_status = status if status >= 0 else 128 - status
        try:
            self.persist()
        except OSError:
            self.fail_io()
        finally:
            self.finished.set()

    async def watch(self):
        await self.provider.wait()
        await asyncio.gather(*self.readers)
        status = self.provider.returncode
        self.exit_status = status if status >= 0 else 128 - status
        try:
            self.persist()
        except OSError:
            self.fail_io()
        if self.controller:
            self.controller[2].set()

    async def orphan(self):
        while not self.finished.is_set():
            if self.controller is None:
                age = asyncio.get_running_loop().time() - self.disconnected_at
                if age >= self.spec.get('orphan_timeout_seconds', 1800):
                    await self.stop()
                    return
            await asyncio.sleep(.05)

    async def run(self):
        try:
            await self.serve()
        except BaseException:
            if hasattr(self, 'provider'):
                self.signal_group(signal.SIGKILL)
                await self.provider.wait()
            raise

    async def serve(self):
        self.provider = await asyncio.create_subprocess_exec(
            *self.spec['argv'], cwd=self.spec['cwd'], env=self.spec['env'],
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, start_new_session=True)
        self.provider_start = None
        try:
            self.provider_start = Path(f'/proc/{self.provider.pid}/stat').read_text().rsplit(')', 1)[1].split()[19]
        except FileNotFoundError:
            pass
        self.manifest = {key: self.spec[key] for key in ('argv', 'cwd', 'backend', 'relay_id', 'spawn_nonce')}
        self.manifest.update(protocol=PROTOCOL, relay_pid=os.getpid(), provider_pid=self.provider.pid,
                             pgid=self.provider.pid, created_at=datetime.now(timezone.utc).isoformat())
        self.persist()
        self.readers = [asyncio.create_task(self.output(self.provider.stdout)),
                        asyncio.create_task(self.output(self.provider.stderr, diagnostic=True))]
        path = self.directory / 'ctl.sock'
        server = await asyncio.start_unix_server(self.receive, path='ctl.sock', limit=self.cap * 2)
        os.chmod(path, 0o600)
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            loop.add_signal_handler(sig, lambda: asyncio.create_task(self.stop()))
        tasks = [asyncio.create_task(self.watch()), asyncio.create_task(self.orphan())]
        try:
            await self.finished.wait()
        finally:
            server.close()
            clients = list(self.clients)
            for client in clients:
                self.disconnect(client)
            await asyncio.gather(*(client.wait_closed() for client in clients), return_exceptions=True)
            await server.wait_closed()
            path.unlink(missing_ok=True)
            for task in tasks:
                task.cancel()
            self.journal.close()
            self.stderr.close()


def sweep_dead_relays(root):
    cutoff = datetime.now(timezone.utc) - timedelta(hours=24)
    for directory in root.iterdir():
        if not directory.is_dir() or directory.is_symlink():
            continue
        try:
            manifest = json.loads((directory / 'relay.json').read_text())
            if manifest.get('exit_status') is None or datetime.fromisoformat(manifest['created_at']) >= cutoff:
                continue
            pid = manifest['relay_pid']
            if type(pid) is not int or pid <= 0:
                continue
            try:
                command = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
                if any(Path(os.fsdecode(argument)).name == 'agent_relay.py' for argument in command):
                    continue
            except FileNotFoundError:
                pass
            shutil.rmtree(directory)
        except (OSError, ValueError, KeyError, TypeError):
            continue


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True)
    parser.add_argument('--spec', required=True)
    arguments = parser.parse_args()
    directory = Path(arguments.directory).absolute()
    spec_path = Path(arguments.spec)
    spec = json.loads(spec_path.read_text())
    spec_path.unlink()
    if (not isinstance(spec.get('argv'), list) or not spec['argv'] or
            not all(isinstance(value, str) for value in spec['argv']) or
            not isinstance(spec.get('env'), dict) or
            not all(isinstance(key, str) and isinstance(value, str) for key, value in spec['env'].items()) or
            not isinstance(spec.get('cwd'), str) or
            not all(isinstance(spec.get(key), str) and spec[key] for key in ('backend', 'relay_id', 'spawn_nonce')) or
            not isinstance(spec.get('orphan_timeout_seconds', 1800), (int, float)) or
            not math.isfinite(spec.get('orphan_timeout_seconds', 1800)) or
            spec.get('orphan_timeout_seconds', 1800) <= 0 or
            type(spec.get('journal_cap', CAP)) is not int or spec.get('journal_cap', CAP) <= 0):
        raise ValueError('invalid relay specification')
    directory.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    sweep_dead_relays(directory.parent)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    if (directory / 'relay.json').exists() or (directory / 'ctl.sock').exists():
        raise ValueError('relay directory already used')
    if os.fork():
        return
    os.setsid()
    if os.fork():
        os._exit(0)
    os.umask(0o077)
    os.chdir(directory)
    with open(os.devnull, 'rb') as null, open(directory / 'relay.log', 'ab', buffering=0) as log:
        os.dup2(null.fileno(), 0)
        os.dup2(log.fileno(), 1)
        os.dup2(log.fileno(), 2)
    try:
        asyncio.run(Relay(directory, spec).run())
    except Exception:
        import traceback
        traceback.print_exc()
        os._exit(1)
    os._exit(0)


if __name__ == '__main__':
    main()
