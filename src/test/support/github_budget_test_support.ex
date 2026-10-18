defmodule Aiur.GitHub.BudgetTestSupport do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Aiur.GitHub.{Budget, CredentialHeadroom}

  def setup do
    root = Aiur.TestSupport.tmp_root!("aiur-github-budget")
    File.mkdir_p!(root)

    previous = Application.get_env(:aiur, :github_budget_enabled?)
    Application.put_env(:aiur, :github_budget_enabled?, true)
    CredentialHeadroom.reset()

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(root)
      restore_env(:github_budget_enabled?, previous)
      CredentialHeadroom.reset()
    end)

    {:ok, root: root}
  end

  def request(token, path), do: %{method: :get, url: "https://api.github.com#{path}", token: token}

  # A hold verdict is returned as soon as the broker answers
  # `wait actor <ms>` / `wait <ms>`, so the only load-sensitive part is
  # `python3` subprocess startup. When that races the per-attempt deadline the
  # broker now reports `:github_budget_broker_timeout` distinctly from a
  # malformed reply (`:github_budget_broker_unavailable`), and this retries the
  # former: the condition behind a hold (an actor already at its ceiling, or a
  # standing shared cooldown) persists, so a timed-out attempt grants nothing
  # and a retry cannot double-consume (#2286).
  def acquire_retrying_timeout(request, opts, attempts \\ 40) do
    case Budget.acquire(request, opts) do
      {:error, :github_budget_broker_timeout} when attempts > 0 ->
        acquire_retrying_timeout(request, opts, attempts - 1)

      result ->
        result
    end
  end

  def secondary_response(seconds) do
    {:ok,
     %{
       status: 403,
       headers: [
         {"x-ratelimit-resource", "core"},
         {"x-ratelimit-limit", "5000"},
         {"x-ratelimit-remaining", "0"},
         {"x-ratelimit-reset", Integer.to_string(System.system_time(:second) + 60)},
         {"retry-after", Integer.to_string(seconds)}
       ],
       body: %{"message" => "You have exceeded a secondary rate limit."}
     }}
  end

  def observe_headroom(request, opts) do
    CredentialHeadroom.observe(
      request,
      {:ok,
       %{
         status: 200,
         headers: [
           {"x-ratelimit-resource", "core"},
           {"x-ratelimit-limit", Integer.to_string(opts[:limit])},
           {"x-ratelimit-remaining", Integer.to_string(opts[:remaining])},
           {"x-ratelimit-reset", Integer.to_string(opts[:reset])}
         ]
       }}
    )
  end

  def lock_database(path) do
    python = System.find_executable("python3") || flunk("python3 is required")

    script = "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1]); c.execute('BEGIN EXCLUSIVE'); print('locked', flush=True); time.sleep(30)"

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(python)},
        [:binary, :exit_status, :stderr_to_stdout, args: [~c"-c", String.to_charlist(script), String.to_charlist(path)]]
      )

    on_exit(fn -> close_port(port) end)
    assert_receive {^port, {:data, "locked\n"}}, 2_000
    port
  end

  # Direct injection of a policy row whose `observed_at_ms` is ten minutes in
  # the past, so the concurrency reconcile must ignore it while the usage report
  # still retains it (the report's window is an hour, the reconcile's is two
  # minutes).
  def insert_stale_policy(db, token_key) do
    stale_at = System.system_time(:millisecond) - 10 * 60 * 1_000

    script =
      "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); " <>
        "c.execute(\"INSERT INTO policies(token_key, consumer_key, consumer_label, max_inflight, " <>
        "max_inflight_per_endpoint, requests_per_minute, stagger_ms, core_limit_per_hour, " <>
        "graphql_limit_per_hour, observed_at_ms) VALUES (?,?,?,1,1,1,0,3,5,?)\", " <>
        "(sys.argv[2], 'stale', 'workspace:/stale', int(sys.argv[3]))); c.commit()"

    {_output, 0} =
      System.cmd("python3", ["-c", script, db, token_key, Integer.to_string(stale_at)], stderr_to_stdout: true)

    :ok
  end

  def create_legacy_budget_database(db) do
    script =
      "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); " <>
        "c.execute('CREATE TABLE admissions (id INTEGER PRIMARY KEY AUTOINCREMENT, token_key TEXT NOT NULL, " <>
        "consumer_key TEXT NOT NULL DEFAULT \\\'\\\', endpoint_family TEXT NOT NULL, admitted_at_ms INTEGER NOT NULL)'); " <>
        "c.commit()"

    assert {_output, 0} = System.cmd("python3", ["-c", script, db], stderr_to_stdout: true)
  end

  # Advances the ledger's `broker_meta` version stamp, simulating a newer broker
  # release having opened the shared ledger before this broker ran.
  def bump_broker_version(db, version) do
    script =
      "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); " <>
        "c.execute(\"INSERT INTO broker_meta(key,value) VALUES('broker_version',?) " <>
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value\", (sys.argv[2],)); c.commit()"

    assert {_output, 0} = System.cmd("python3", ["-c", script, db, Integer.to_string(version)], stderr_to_stdout: true)
  end

  # The admission a pre-#2284 writer produced: linked to no lease, still flagged
  # billable. Injected straight into the broker database so the "lease-less rows
  # stay billable" contract is exercised against real storage.
  #
  # The `admissions_require_lease` trigger (#2307) refuses exactly this insert:
  # that is its job, since a live stale broker must never write a lease-less
  # row. The row this fixture needs is one written *before* the trigger existed,
  # so the trigger is dropped for the insert; the next writable broker open
  # reinstalls it (`_prepare_writable` is `CREATE TRIGGER IF NOT EXISTS`). Both
  # contracts hold: stale brokers are still refused, and the legacy rows they
  # left behind are still read as billable spend.
  def insert_lease_less_admission(db, token, consumer_key, endpoint_family, billable) do
    key = Budget.token_key(token)
    now = System.system_time(:millisecond)

    script =
      "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); " <>
        "c.execute('DROP TRIGGER IF EXISTS admissions_require_lease'); " <>
        "c.execute('INSERT INTO admissions(token_key, consumer_key, lease_id, endpoint_family, admitted_at_ms, billable) " <>
        "VALUES (?,?,NULL,?,?,?)', (sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6]))); c.commit()"

    case System.cmd("python3", ["-c", script, db, key, consumer_key, endpoint_family, Integer.to_string(now), Integer.to_string(billable)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("could not inject lease-less admission: #{status}: #{output}")
    end
  end

  def close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  def broker_wrapper(root, pid_path) do
    path = Path.join(root, "python-wrapper")
    File.write!(path, "#!/bin/sh\nprintf '%s' \"$$\" > \"#{pid_path}\"\nexec python3 \"$@\"\n")
    File.chmod!(path, 0o755)
    path
  end

  def assert_process_exits(pid),
    do:
      assert(
        {_, 0} =
          System.cmd("timeout", ["3s", "bash", "-c", "while IFS= read -r s < /proc/$1/stat; do s=${s##*) }; s=${s%% *}; [[ $s == Z ]] && exit 0; sleep 0.01; done", "_", pid], stderr_to_stdout: true)
      )

  def wait_until(predicate, attempts \\ 300) do
    cond do
      predicate.() -> :ok
      attempts <= 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(predicate, attempts - 1)
    end
  end

  def restore_env(key, nil), do: Application.delete_env(:aiur, key)
  def restore_env(key, value), do: Application.put_env(:aiur, key, value)
end
