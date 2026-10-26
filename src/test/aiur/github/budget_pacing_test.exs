defmodule Aiur.GitHub.BudgetPacingTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.{Budget, CredentialHeadroom}

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-github-budget-pacing")
    File.mkdir_p!(root)

    previous = Application.get_env(:aiur, :github_budget_enabled?)
    Application.put_env(:aiur, :github_budget_enabled?, true)
    CredentialHeadroom.reset()

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(root)

      if is_nil(previous),
        do: Application.delete_env(:aiur, :github_budget_enabled?),
        else: Application.put_env(:aiur, :github_budget_enabled?, previous)

      CredentialHeadroom.reset()
    end)

    {:ok, root: root}
  end

  # The live daemon token sat at 120 admissions per minute for a fifth of an
  # hour while its rolling hour was 4,163 of 12,000 (#4496): the default pacer
  # allowed only 7,200 an hour, so it held below the hourly ceiling.
  test "the default pacer does not hold a burst while the rolling hour is under the ceiling", %{root: root} do
    opts = [state_dir: root, stagger_ms: 0, timeout_ms: 2_000, daemon_core_limit_per_hour: 12_000, agent_core_limit_per_hour: 12_000]
    request = request("busy-daemon-token", "/repos/owner/repo/issues/4496")

    # The first admission creates the ledger the burst is injected into.
    assert {:ok, first} = acquire_retrying_timeout(request, opts)
    assert :ok = Budget.release(first, opts)
    insert_recent_admissions(Budget.database_path(state_dir: root), "busy-daemon-token", "daemon:burst", 150)

    assert {:ok, lease} = acquire_retrying_timeout(request, opts)
    assert :ok = Budget.release(lease, opts)
  end

  defp request(token, path), do: %{method: :get, url: "https://api.github.com#{path}", token: token}

  # Retries only a python3 startup that raced the deadline; a hold is returned as is.
  defp acquire_retrying_timeout(request, opts, attempts \\ 40) do
    case Budget.acquire(request, opts) do
      {:error, :github_budget_broker_timeout} when attempts > 0 -> acquire_retrying_timeout(request, opts, attempts - 1)
      result -> result
    end
  end

  defp insert_recent_admissions(db, token, consumer_label, count) do
    script =
      "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1]); now=int(time.time()*1000); " <>
        "c.execute('DROP TRIGGER IF EXISTS admissions_require_lease'); " <>
        "c.executemany('INSERT INTO admissions(token_key, consumer_key, lease_id, endpoint_family, admitted_at_ms, billable) " <>
        "VALUES (?,?,NULL,?,?,1)', [(sys.argv[2], sys.argv[3], 'issues', now - i * 100) for i in range(int(sys.argv[4]))]); c.commit()"

    args = ["-c", script, db, Budget.token_key(token), Budget.token_key(consumer_label), Integer.to_string(count)]

    case System.cmd("python3", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("could not inject admissions: #{status}: #{output}")
    end
  end
end
