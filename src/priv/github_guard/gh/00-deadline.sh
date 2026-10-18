# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
#!/bin/sh
# Keep the complete governed call, including broker and real-gh descendants,
# inside one process group so a deadline can terminate every child.
if command -v python3 >/dev/null 2>&1; then
  exec python3 -I -c '
import os, signal, subprocess, sys, threading

script = sys.argv[1]
args = sys.argv[2:]
with open(script, encoding="utf-8") as source:
    assembled = source.read()
marker = "# @aiur-deadline-body@\n"
if marker not in assembled:
    print("aiur: governed gh guard has no deadline body", file=sys.stderr)
    raise SystemExit(127)
body = assembled.split(marker, 1)[1]
try:
    seconds = int(os.environ.get("AIUR_GH_CALL_TIMEOUT_SECONDS", "120"))
except ValueError:
    seconds = 120
seconds = max(1, min(seconds, 120))

# Feed the large body through an anonymous pipe. The shell inherits the read
# end and sources it by descriptor; no agent-writable pathname exists.
body_read, body_write = os.pipe()
def write_body(fd, contents):
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as body_file:
            body_file.write(contents)
    except BrokenPipeError:
        # A guard rejection can exit before reading the entire body. The
        # supervisor still joins this writer, so it must treat the closed
        # source pipe as normal child completion.
        pass

shell_program = (
    "source_path=$1; shift; "
    "if [ -f \"$source_path\" ]; then "
    "echo \"aiur: refusing regular-file deadline body\" >&2; exit 127; "
    "fi; . \"$source_path\""
)
child = subprocess.Popen(
    ["/bin/sh", "-c", shell_program, script, "/dev/fd/" + str(body_read), *args],
    stdin=None,
    pass_fds=(body_read,),
    start_new_session=True,
)
os.close(body_read)
writer = threading.Thread(target=lambda: write_body(body_write, body), daemon=True)
writer.start()

def terminate_process_group():
    descendants = descendant_pids(child.pid)
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    for pid in descendants:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        child.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    for pid in descendants:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    child.wait()

def descendant_pids(root):
    parents = {}
    try:
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            try:
                with open(f"/proc/{entry}/stat", encoding="ascii") as stat_file:
                    fields = stat_file.read().rsplit(")", 1)[1].split()
                parents[int(entry)] = int(fields[1])
            except (OSError, ValueError, IndexError):
                continue
    except OSError:
        try:
            listing = subprocess.run(["ps", "-axo", "pid=,ppid="], check=True, capture_output=True, text=True).stdout
            parents = {int(pid): int(parent) for line in listing.splitlines() if len(line.split()) == 2 for pid, parent in [line.split()]}
        except (OSError, ValueError, subprocess.CalledProcessError):
            return []
    found = {root}
    descendants = []
    while True:
        children = [pid for pid, parent in parents.items() if parent in found and pid not in found]
        if not children:
            return descendants
        found.update(children)
        descendants.extend(children)

def stop_child(signum, _frame):
    terminate_process_group()
    writer.join(timeout=0.5)
    raise SystemExit(128 + signum)

signal.signal(signal.SIGTERM, stop_child)
signal.signal(signal.SIGINT, stop_child)
signal.signal(signal.SIGHUP, stop_child)
try:
    child.wait(timeout=seconds)
except subprocess.TimeoutExpired:
    terminate_process_group()
    writer.join(timeout=0.5)
    print(f"aiur: governed gh call exceeded {seconds}s deadline; terminated process group", file=sys.stderr)
    raise SystemExit(124)
writer.join(timeout=0.5)
status = child.returncode
raise SystemExit(status if status >= 0 else 128 - status)
' "$0" "$@" 3</dev/null
elif [ "${1:-}" != --validate-issue-command ]; then
  printf '%s\n' 'aiur: python3 is required to enforce the governed gh call deadline' >&2
  exit 127
fi
# The supervised child starts here, after the launcher, so no inherited
# environment marker can bypass the deadline by skipping the launcher.
# @aiur-deadline-body@
