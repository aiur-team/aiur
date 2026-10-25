defmodule Aiur.AgentGitHubGuardCacheSupport do
  @moduledoc false
  # State-cache and budget-broker fixtures for `Aiur.AgentGitHubGuardCase` tests.

  import Aiur.AgentGitHubGuardTestSupport
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Aiur.AgentGitHubGuard
  alias Aiur.GitHub.Budget

  def cache_state_dir(context), do: Path.join(context.workspace, "budget-state")

  # The workspace anchor requires the process to actually be inside the
  # workspace, and a shell derives `$PWD` at startup, so both are supplied.
  def run_cached_guard(context, args, extra_env \\ [], opts \\ []) do
    directory = Keyword.get(opts, :cd, context.workspace)

    base = [
      {"AIUR_GITHUB_BUDGET_ROOT", cache_state_dir(context)},
      {"AIUR_GITHUB_BUDGET_ENABLED", "0"},
      {"AIUR_GITHUB_REPO", "owner/repo"},
      {"PWD", directory}
    ]

    # Merged by name rather than appended, so a test enabling the broker replaces
    # the default instead of relying on which duplicate the port layer keeps.
    overrides = Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end)
    env = Enum.reject(base, fn {name, _value} -> List.keymember?(overrides, name, 0) end) ++ overrides

    System.cmd(context.wrapper, args, env: guard_env(context) ++ env, cd: directory, stderr_to_stdout: true)
  end

  # The shared admission broker, which is what makes one fetcher out of many
  # simultaneous identical readers. Every other cache test runs without it,
  # because caching must work whether or not the broker is available.
  def broker_token_key, do: "b" <> String.duplicate("0", 63)

  def broker_env(context) do
    [
      AIUR_GITHUB_BUDGET_ENABLED: "1",
      AIUR_GITHUB_BUDGET_KEY: broker_token_key(),
      AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace)
    ]
  end

  # The daemon opens the shared broker ledger before it dispatches agents. These
  # tests create a private ledger per case, so initialize it synchronously before
  # asking concurrent readers to prove the steady-state coalescing contract. The
  # completed guard call is the readiness signal; no wall-clock bound is involved.
  def warm_cache_broker(context) do
    assert {"ok\n", 0} = run_cached_guard(context, ["pr", "view", "1669", "--json", "body"], broker_env(context))
    File.rm!(context.calls)
  end

  # `FAKE_GH_SLEEP` holds the leader's call open long enough that every follower
  # is genuinely in flight while it runs. Without an overlap there is no
  # coalescing to observe, only caching.
  def concurrent_reads(context, args, count) do
    warm_cache_broker(context)

    env =
      broker_env(context) ++
        [
          FAKE_GH_SLEEP: "1",
          # Concurrency limits deliberately raised past the reader count and the
          # stagger removed. Left at their defaults the in-flight ceiling would
          # serialise most of these readers, and the later ones would be answered
          # by the stored entry — so the test would pass on caching alone and say
          # nothing about coalescing. With every reader admissible at once, the
          # only thing that can hold the count at one is the claim.
          AIUR_GITHUB_MAX_INFLIGHT: Integer.to_string(count + 1),
          AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT: Integer.to_string(count + 1),
          AIUR_GITHUB_REQUESTS_PER_MINUTE: "600",
          AIUR_GITHUB_STAGGER_MS: "0"
        ]

    1..count
    |> Task.async_stream(fn _index -> run_cached_guard(context, args, env) end,
      max_concurrency: count,
      timeout: 120_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  # Rows the wrapper wrote to its own effectiveness log, by outcome.
  def cache_events(context, outcome) do
    [context.state_path, "github-quota", "agent-cache.tsv"]
    |> Path.join()
    |> File.read()
    |> case do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.count(fn row -> row |> String.split("\t") |> Enum.at(2) == outcome end)

      _missing ->
        0
    end
  end

  def last_cache_miss_reason(context) do
    [context.state_path, "github-quota", "agent-cache.tsv"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(fn row ->
      case String.split(row, "\t") do
        [_at, _consumer, "miss", _kind, _id, reason] -> reason
        _other -> nil
      end
    end)
  end

  # Each stored answer as the broker names it: `owner/repo/kind/id/<shape>`.
  def cached_shapes(context) do
    [cache_state_dir(context), "state-cache/v1/**/*.body"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(fn body ->
      key =
        body
        |> Path.relative_to(Path.join(cache_state_dir(context), "state-cache/v1"))
        |> String.replace_suffix(".body", "")

      {key, body}
    end)
  end

  def upstream_calls(context), do: line_count(context.calls)

  def line_count(path) do
    case File.read(path) do
      {:ok, contents} -> contents |> String.split("\n", trim: true) |> length()
      _missing -> 0
    end
  end

  # A broker that delegates every command to the real broker except `reconcile`,
  # where it mimics a pre-#2284 broker's argparse failure. This exercises the
  # reconcile-path structural detection (the code path that surfaces a broker
  # which can acquire a lease but cannot reconcile 304s) without depending on
  # argparse's exact error wording, which the guard deliberately does not match
  # (#2307).
  def stale_broker_path(context) do
    path = Path.join(context.workspace, "stale-broker.py")
    real = Budget.broker_path()

    File.write!(path, """
    #!/usr/bin/env python3
    import subprocess
    import sys
    if sys.argv[1] == "reconcile":
        sys.stderr.write("usage: aiur-github-budget [-h] command ...\\n")
        sys.stderr.write("aiur-github-budget: error: argument command: invalid choice: 'reconcile' (choose from 'acquire', 'release', 'renew', 'hold')\\n")
        sys.exit(2)
    sys.exit(subprocess.call([sys.executable, "#{real}"] + sys.argv[1:]))
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A HEALTHY broker that warns on stderr before delegating — a Python
  # DeprecationWarning, a wrapper notice, a locale complaint. The acquire
  # response is still a real grant on stdout; the guard must take the last
  # non-empty line rather than prefix-match the merged 2>&1 stream, or this
  # broker's noise would turn admission into a hard 75 (#2307 review).
  def noisy_broker_path(context) do
    path = Path.join(context.workspace, "noisy-broker.py")
    real = Budget.broker_path()

    File.write!(path, """
    #!/usr/bin/env python3
    import subprocess
    import sys
    sys.stderr.write("DeprecationWarning: aiur-github-budget: consider --legacy-broker\\n")
    sys.exit(subprocess.call([sys.executable, "#{real}"] + sys.argv[1:]))
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A broker that delegates every command to the real broker except `reconcile`,
  # where it fails with a message the pre-#2307 three-literal allowlist would
  # NOT have matched (a Python runtime error — broken install, unreadable
  # ledger — not argparse's "invalid choice" and not the ledger's own
  # trigger/stamp strings). This pins the widened structural detection: any
  # non-transient reconcile failure must surface one fleet alert, or a silently
  # broken broker would go undetected (#2307 review).
  # A broker that is healthy but INTERRUPTED mid-reconcile — killed by a signal,
  # printing nothing. The daemon-side equivalent is the broker timeout of #2457.
  # `acquire`/`release` still delegate to the real broker, so the workspace is
  # provably not stale; only the reconcile call dies.
  def killed_reconcile_broker_path(context) do
    path = Path.join(context.workspace, "killed-reconcile-broker.py")
    real = Budget.broker_path()

    File.write!(path, """
    #!/usr/bin/env python3
    import os
    import signal
    import subprocess
    import sys
    if sys.argv[1] == "reconcile":
        os.kill(os.getpid(), signal.SIGKILL)
    sys.exit(subprocess.call([sys.executable, "#{real}"] + sys.argv[1:]))
    """)

    File.chmod!(path, 0o755)
    path
  end

  def broken_reconcile_broker_path(context) do
    path = Path.join(context.workspace, "broken-reconcile-broker.py")
    real = Budget.broker_path()

    File.write!(path, """
    #!/usr/bin/env python3
    import subprocess
    import sys
    if sys.argv[1] == "reconcile":
        raise RuntimeError("aiur-github-budget: reconcile failed: ledger unreadable: permission denied")
    sys.exit(subprocess.call([sys.executable, "#{real}"] + sys.argv[1:]))
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A faithful pre-#2284 broker: `acquire` writes the old admission INSERT that
  # names no `lease_id`, exactly like the brokers that are stale in production.
  # Against a ledger the current broker has opened (its `admissions_require_lease`
  # trigger installed) that INSERT aborts with the trigger's message and acquire
  # exits non-zero — the real failure shape the guard must fail OPEN on, not the
  # hypothetical reconcile-only broker (#2307 review).
  def pre2284_broker_path(context) do
    path = Path.join(context.workspace, "pre2284-broker.py")

    File.write!(path, """
    #!/usr/bin/env python3
    import sqlite3
    import sys

    def arg(name):
        for index, item in enumerate(sys.argv):
            if item == name and index + 1 < len(sys.argv):
                return sys.argv[index + 1]
        return None

    if sys.argv[1] == "acquire":
        conn = sqlite3.connect(arg("--db"))
        try:
            conn.execute(
                "INSERT INTO admissions(token_key, consumer_key, endpoint_family, admitted_at_ms) VALUES (?, ?, ?, ?)",
                (arg("--token-key"), arg("--consumer-key"), arg("--endpoint-family"), 1),
            )
            conn.commit()
        finally:
            conn.close()
        sys.exit(0)
    sys.stderr.write("aiur-github-budget: error: argument command: invalid choice: 'reconcile'\\n")
    sys.exit(2)
    """)

    File.chmod!(path, 0o755)
    path
  end

  # The installed broker, wrapped so each process announces itself just before it
  # takes its migration decision. `runpy` runs the real file as `__main__`, so
  # the broker's own argument parsing, output and exit status are exactly what
  # the wrapper would have seen without the shim.
  #
  # The shim opens the ledger and reads the schema before writing its marker.
  # That is not the broker's probe — it is what makes the marker mean something:
  # the interpreter is up, `sqlite3` is imported and the file's pages are warm,
  # so a marker says this process is close to its probe rather than a few
  # milliseconds of cold start away from it.
  def start_marking_broker(context, marker_dir) do
    path = Path.join(context.state_path, "start-marking-broker.py")
    real = AgentGitHubGuard.budget_broker_path(context.workspace)
    File.mkdir_p!(marker_dir)

    File.write!(path, """
    import os, runpy, sqlite3, sys

    # Every broker subcommand the wrapper issues carries `--db`. If one ever does
    # not, warm nothing rather than dying here: a shim that raises would surface
    # as an unexplained broker failure in a test that is not about the shim.
    if "--db" in sys.argv:
        warm = sqlite3.connect(sys.argv[sys.argv.index("--db") + 1])
        warm.execute("PRAGMA table_info(admissions)").fetchall()
        warm.close()

    open(os.path.join(#{inspect(marker_dir)}, str(os.getpid())), "w").close()
    runpy.run_path(#{inspect(real)}, run_name="__main__")
    """)

    File.chmod!(path, 0o755)
    path
  end

  # Rewinds one column out of the ledger, producing the pre-migration shape a
  # broker has to repair on startup.
  def drop_ledger_column!(database, table, column) do
    assert {_output, 0} =
             System.cmd("python3", [
               "-c",
               "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); " <>
                 "c.execute('ALTER TABLE %s DROP COLUMN %s' % (sys.argv[2], sys.argv[3])); c.commit()",
               database,
               table,
               column
             ])
  end

  # Holds the ledger's write lock. Readers are unaffected — WAL keeps them
  # running — so a broker blocked by this has already read everything it reads
  # and is stopped at its first write.
  def lock_database(path) do
    python = System.find_executable("python3") || flunk("python3 is required")

    script =
      "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1]); c.execute('BEGIN EXCLUSIVE'); " <>
        "print('locked', flush=True); time.sleep(60)"

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(python)},
        [:binary, :exit_status, :stderr_to_stdout, args: [~c"-c", String.to_charlist(script), String.to_charlist(path)]]
      )

    on_exit(fn -> close_port(port) end)
    assert_receive {^port, {:data, "locked\n"}}, 5_000
    port
  end

  # Killing the holder is what releases the ledger, and it is also what makes the
  # port die — so between reading its pid and closing it the port may already be
  # gone, and `Port.close/1` on a dead port raises. Both the test body and the
  # `on_exit` cleanup call this, so a second call must be a no-op rather than an
  # error.
  def close_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      nil -> :ok
    end

    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
