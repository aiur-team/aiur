# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.

# `gh api --paginate` normally makes its follow-up requests inside one gh
# process. Re-enter this guard for each REST page instead, so every network
# request obtains and releases its own shared broker lease. The child is also
# responsible for response observation and quota tracking; it has no
# `--paginate` flag, so it follows the ordinary single-request path.
run_budgeted_paginated_api() {
  AIUR_GITHUB_PAGINATION_WRAPPER="$0" AIUR_GITHUB_PAGINATION_REAL_GH="$real_gh" AIUR_GITHUB_PAGINATION_DIRECTION="$direction" python3 -I - "$@" <<'PY'
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import threading
from urllib.parse import urlsplit


def split_response(output):
    match = re.search(br"\r?\n\r?\n", output)
    if match is None:
        return b"", output
    return output[: match.start()], output[match.end() :]


def next_endpoint(headers):
    for line in headers.decode("utf-8", "replace").splitlines():
        if not line.lower().startswith("link:"):
            continue
        match = re.search(r'<([^>]+)>;\s*rel="next"', line, re.IGNORECASE)
        if match is None:
            continue
        parsed = urlsplit(match.group(1))
        endpoint = parsed.path or "/"
        return f"{endpoint}?{parsed.query}" if parsed.query else endpoint
    return None


def next_cursor(body):
    try:
        response = json.loads(body)
    except json.JSONDecodeError:
        print("aiur: gh api GraphQL pagination returned a non-JSON page", file=sys.stderr)
        raise SystemExit(1)

    stack = [response]
    while stack:
        value = stack.pop()
        if isinstance(value, dict):
            if {"hasNextPage", "endCursor"} <= value.keys():
                if not value["hasNextPage"]:
                    return None
                cursor = value["endCursor"]
                if isinstance(cursor, str) and cursor:
                    return cursor
                print("aiur: gh api GraphQL pagination returned an invalid endCursor", file=sys.stderr)
                raise SystemExit(1)
            stack.extend(value.values())
        elif isinstance(value, list):
            stack.extend(value)

    print("aiur: gh api GraphQL pagination response is missing pageInfo", file=sys.stderr)
    raise SystemExit(1)


def endpoint_index(args):
    value_flags = {
        "--cache", "-F", "--field", "-f", "--raw-field", "-H", "--header",
        "--hostname", "--input", "-q", "--jq", "-X", "--method", "-p",
        "--preview", "-t", "--template",
    }
    awaiting_value = False

    for index, arg in enumerate(args[1:], start=1):
        if awaiting_value:
            awaiting_value = False
            continue
        if arg == "--":
            return index + 1 if index + 1 < len(args) else None
        if arg in value_flags:
            awaiting_value = True
            continue
        if arg in {"--include", "-i", "--silent", "--verbose"}:
            continue
        if arg.startswith("--"):
            continue
        if arg.startswith("-"):
            if arg[:2] in {"-F", "-f", "-H", "-q", "-X", "-p", "-t"} and len(arg) > 2:
                continue
            return None
        return index

    return None


def active_flag(args, *values):
    options = True

    for arg in args:
        if options and arg == "--":
            options = False
        elif options and (arg in values or any(value.startswith("--") and arg == f"{value}=true" for value in values)):
            return True

    return False


def without_pagination_flags(args):
    page_args = []
    options = True

    for arg in args:
        if options and arg == "--":
            options = False
        if options and arg in {"--paginate", "--paginate=true", "--slurp", "--slurp=true"}:
            continue
        page_args.append(arg)

    return page_args


def extract_output_formatter(args):
    """Keep one unformatted request per page and retain gh's formatter args."""

    page_args = []
    formatter = None
    index = 0
    options = True

    while index < len(args):
        arg = args[index]
        if options and arg == "--":
            options = False
            page_args.extend(args[index:])
            break

        kind = None
        expression = None
        if options and arg in {"-q", "--jq", "-t", "--template"}:
            if index + 1 >= len(args):
                print(f"aiur: {arg} requires an output expression", file=sys.stderr)
                raise SystemExit(64)
            kind = "jq" if arg in {"-q", "--jq"} else "template"
            expression = args[index + 1]
            index += 2
        elif options and arg.startswith("--jq="):
            kind, expression = "jq", arg.split("=", 1)[1]
            index += 1
        elif options and arg.startswith("--template="):
            kind, expression = "template", arg.split("=", 1)[1]
            index += 1
        elif options and arg.startswith("-q") and len(arg) > 2:
            kind, expression = "jq", arg[2:]
            index += 1
        elif options and arg.startswith("-t") and len(arg) > 2:
            kind, expression = "template", arg[2:]
            index += 1
        else:
            page_args.append(arg)
            index += 1
            continue

        if formatter is not None:
            print("aiur: gh api accepts only one output formatter", file=sys.stderr)
            raise SystemExit(64)
        formatter = (kind, expression)

    return page_args, formatter


def paginated_request_uses_input(args):
    value_flags = {"-F", "--field", "-f", "--raw-field"}

    for index, arg in enumerate(args):
        if arg == "--input" or arg.startswith("--input="):
            return True
        if arg in value_flags and index + 1 < len(args):
            value = args[index + 1]
            if "=@" in value:
                return True
        if "=@" in arg and (
            arg.startswith(("-F", "-f")) or arg.startswith(("--field=", "--raw-field="))
        ):
            return True

    return False


def add_include(args):
    if active_flag(args, "--include", "-i"):
        return args

    page_args = args.copy()
    try:
        page_args.insert(page_args.index("--"), "--include")
    except ValueError:
        page_args.append("--include")
    return page_args


def formatter_arguments(formatter):
    kind, expression = formatter
    return ["--jq" if kind == "jq" else "--template", expression]


def response_status(headers):
    match = re.search(br"^HTTP/[^\s]+\s+(\d{3})", headers)
    return int(match.group(1)) if match else 200


def response_headers(headers):
    for line in headers.splitlines()[1:]:
        if b":" not in line:
            continue
        name, value = line.split(b":", 1)
        name = name.decode("latin-1")
        if name.lower() in {"connection", "content-length", "link", "transfer-encoding"}:
            continue
        yield name, value.decode("latin-1").strip()


def response_header_values(headers, name):
    prefix = name.lower().encode("ascii") + b":"
    return [line for line in headers.splitlines()[1:] if line.lower().startswith(prefix)]


def linux_process_owns_connection(pid, client_port, server_port):
    """Verify the renderer owns the client side of this loopback connection."""

    inode = None
    try:
        with open("/proc/net/tcp", encoding="ascii") as connections:
            for line in connections.readlines()[1:]:
                fields = line.split()
                local_port = int(fields[1].rsplit(":", 1)[1], 16)
                remote_port = int(fields[2].rsplit(":", 1)[1], 16)
                if fields[3] == "01" and local_port == client_port and remote_port == server_port:
                    inode = fields[9]
                    break
    except (FileNotFoundError, OSError, ValueError, IndexError):
        return False

    if inode is None:
        return False

    expected = f"socket:[{inode}]"
    try:
        file_descriptors = os.listdir(f"/proc/{pid}/fd")
    except (FileNotFoundError, OSError):
        return False

    for fd in file_descriptors:
        try:
            if os.readlink(f"/proc/{pid}/fd/{fd}") == expected:
                return True
        except (FileNotFoundError, OSError):
            continue
    return False


def darwin_process_owns_connection(pid, client_port, server_port):
    """Use macOS's system lsof to bind the replay to the renderer process."""

    lsof = shutil.which("lsof")
    if lsof is None and os.path.isfile("/usr/sbin/lsof"):
        lsof = "/usr/sbin/lsof"
    if lsof is None:
        return False

    try:
        result = subprocess.run(
            [lsof, "-nP", "-a", "-p", str(pid), "-iTCP"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    connection = f"127.0.0.1:{client_port}->127.0.0.1:{server_port}"
    return result.returncode == 0 and connection in result.stdout


def process_owns_connection(pid, client_port, server_port):
    if sys.platform.startswith("linux"):
        return linux_process_owns_connection(pid, client_port, server_port)
    if sys.platform == "darwin":
        return darwin_process_owns_connection(pid, client_port, server_port)
    return False


def render_with_native_gh(formatter, captured_pages, slurp, include_headers):
    """Replay admitted responses locally and let gh render them unchanged.

    Calling gh once more against GitHub would bypass the captured page's lease.
    A loopback replay keeps the formatter in gh itself (including its embedded
    jq, Go-template helpers, and table state) without another GitHub request.
    """

    if slurp:
        try:
            payload = json.dumps([json.loads(body) for _headers, body in captured_pages]).encode("utf-8")
        except json.JSONDecodeError:
            print("aiur: gh api --paginate --slurp returned a non-JSON page", file=sys.stderr)
            raise SystemExit(1)
        replay_pages = [(b"", payload)]
        paginate = False
    else:
        replay_pages = captured_pages
        paginate = True

    class ReplayHandler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            self.server.renderer_ready.wait(timeout=5)
            renderer_pid = self.server.renderer_pid
            if renderer_pid is None or not process_owns_connection(
                renderer_pid, self.client_address[1], self.server.server_port
            ):
                self.send_error(403)
                return

            match = re.fullmatch(r"/(\d+)", self.path.split("?", 1)[0])
            page = int(match.group(1)) if match else -1
            if not 0 <= page < len(replay_pages):
                self.send_error(404)
                return

            headers, body = replay_pages[page]
            self.send_response(response_status(headers))
            content_type = False
            for name, value in response_headers(headers):
                content_type = content_type or name.lower() == "content-type"
                self.send_header(name, value)
            if not content_type:
                self.send_header("Content-Type", "application/json")
            if page + 1 < len(replay_pages):
                self.send_header("Link", f"<http://127.0.0.1:{self.server.server_port}/{page + 1}>; rel=\"next\"")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def send_response(self, code, message=None):
            # Preserve captured response headers instead of adding the replay
            # server's own Server and Date headers to --include output.
            self.send_response_only(code, message)

        def log_message(self, _format, *_args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ReplayHandler)
    server.daemon_threads = True
    server.block_on_close = False
    server.renderer_pid = None
    server.renderer_ready = threading.Event()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        command = [os.environ["AIUR_GITHUB_PAGINATION_REAL_GH"], "api", f"http://127.0.0.1:{server.server_port}/0"]
        if paginate:
            command.append("--paginate")
        if include_headers:
            command.append("--include")
        command.extend(formatter_arguments(formatter))
        environment = os.environ.copy()
        for name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"):
            environment.pop(name, None)
        # gh requires an authentication source before it will issue even an
        # absolute loopback request. Replace inherited credentials with a
        # fixed non-secret accepted only by this renderer-bound local server.
        environment["GH_TOKEN"] = "aiur-local-replay"
        environment["NO_PROXY"] = "127.0.0.1,localhost"
        environment["no_proxy"] = "127.0.0.1,localhost"
        capture_headers = include_headers and paginate
        process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE if capture_headers else None)
        server.renderer_pid = process.pid
        server.renderer_ready.set()
        rendered, _stderr = process.communicate()

        if capture_headers:
            for page, (headers, _body) in enumerate(replay_pages[:-1]):
                local = f'Link: <http://127.0.0.1:{server.server_port}/{page + 1}>; rel="next"'.encode("ascii")
                original = b"\n".join(response_header_values(headers, "Link"))
                rendered = rendered.replace(local, original)
            sys.stdout.buffer.write(rendered)

        return process.returncode
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


args = sys.argv[1:]
include_headers = active_flag(args, "--include", "-i")
slurp = active_flag(args, "--slurp")
silent = active_flag(args, "--silent")
verbose = active_flag(args, "--verbose")
display_args = without_pagination_flags(args)
raw_args, formatter = extract_output_formatter(display_args)

if formatter and (silent or verbose):
    print("only one of `--template`, `--jq`, `--silent`, or `--verbose` may be used", file=sys.stderr)
    raise SystemExit(1)

raw_args = add_include(raw_args)
raw_endpoint_index = endpoint_index(raw_args)

if raw_endpoint_index is None or raw_args[0] != "api":
    print("aiur: cannot budget malformed gh api pagination command", file=sys.stderr)
    raise SystemExit(64)

if paginated_request_uses_input(raw_args):
    print("aiur: cannot budget gh api --paginate commands that use an input body or standard input", file=sys.stderr)
    raise SystemExit(64)

if os.environ.get("AIUR_GITHUB_PAGINATION_DIRECTION") == "write":
    print("aiur: cannot budget a paginated write", file=sys.stderr)
    raise SystemExit(64)

wrapper = os.environ["AIUR_GITHUB_PAGINATION_WRAPPER"]
pages = []
captured_pages = []
graphql = raw_args[raw_endpoint_index] in {"graphql", "/graphql"}

raw_cursor_arg_index = next(
    (
        index
        for index, arg in enumerate(raw_args)
        if index > 0
        and arg.startswith("endCursor=")
        and raw_args[index - 1] in {"-F", "--field", "-f", "--raw-field"}
    ),
    None,
)

while True:
    result = subprocess.run([wrapper, *raw_args], stdout=subprocess.PIPE)
    headers, body = split_response(result.stdout)

    if result.returncode:
        if not silent:
            if include_headers:
                sys.stdout.buffer.write(headers)
                if headers:
                    sys.stdout.buffer.write(b"\n\n")
            sys.stdout.buffer.write(body)
        raise SystemExit(result.returncode)

    if silent:
        pass
    elif formatter:
        captured_pages.append((headers, body))
    elif slurp:
        try:
            pages.append(json.loads(body))
        except json.JSONDecodeError:
            print("aiur: gh api --paginate --slurp returned a non-JSON page", file=sys.stderr)
            raise SystemExit(1)
    else:
        if include_headers:
            sys.stdout.buffer.write(headers)
            if headers:
                sys.stdout.buffer.write(b"\n\n")
        sys.stdout.buffer.write(body)

    if graphql:
        cursor = next_cursor(body)
        if cursor is None:
            break
        if raw_cursor_arg_index is None:
            raw_args.extend(["-F", f"endCursor={cursor}"])
            raw_cursor_arg_index = len(raw_args) - 1
        else:
            raw_args[raw_cursor_arg_index] = f"endCursor={cursor}"
    else:
        endpoint = next_endpoint(headers)
        if endpoint is None:
            break
        raw_args[raw_endpoint_index] = endpoint

if formatter:
    raise SystemExit(render_with_native_gh(formatter, captured_pages, slurp, include_headers))

if slurp:
    payload = json.dumps(pages).encode("utf-8")
    if not silent:
        sys.stdout.buffer.write(payload)
        sys.stdout.buffer.write(b"\n")
PY
}

