defmodule Aiur.GitHub.Budget.LeaseRenewalTest do
  use ExUnit.Case, async: false

  import Aiur.GitHub.BudgetTestSupport

  alias Aiur.GitHub.{Budget, BudgetTestSupport}

  # NUC, 2026-11-23: two `gh pr view` calls were killed before releasing their
  # leases, and the guard's renewer loops went on renewing them. They filled the
  # token's two `pulls` slots for over 30 minutes, so every PR lookup by both
  # daemons and every agent was held while GitHub reported 4412/5000 left.

  setup do
    BudgetTestSupport.setup()
  end

  test "a released lease is not renewed back into a slot", %{root: root} do
    opts = [state_dir: root, stagger_ms: 0]
    assert {:ok, lease} = Budget.acquire(request("renew-token", "/repos/owner/repo/pulls/1"), opts)
    assert {:ok, _output} = renew(lease, opts)

    assert :ok = Budget.release(lease, opts)
    assert {:error, _reason} = renew(lease, opts)
  end

  test "a lease older than any governed gh call is not renewed", %{root: root} do
    opts = [state_dir: root, stagger_ms: 0]
    assert {:ok, lease} = Budget.acquire(request("renew-token", "/repos/owner/repo/pulls/1"), opts)

    backdate_admission!(Budget.database_path(opts), lease.id, :timer.minutes(11))
    assert {:error, _reason} = renew(lease, opts)
  end

  defp renew(lease, opts), do: Budget.command(["renew", "--lease-id", lease.id, "--lease-ttl-ms", "30000"], lease.token_key, opts)

  defp backdate_admission!(db, lease_id, age_ms) do
    script =
      "import sqlite3, sys, time; c = sqlite3.connect(sys.argv[1]); c.execute('UPDATE admissions SET admitted_at_ms = ? WHERE lease_id = ?', (int(time.time() * 1000) - int(sys.argv[3]), sys.argv[2])); c.commit()"

    {_output, 0} = System.cmd("python3", ["-I", "-c", script, db, lease_id, Integer.to_string(age_ms)])
  end
end
