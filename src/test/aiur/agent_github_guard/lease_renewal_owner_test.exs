defmodule Aiur.AgentGitHubGuard.LeaseRenewalOwnerTest do
  use ExUnit.Case, async: true

  # NUC, 2026-11-23: a governed `gh pr view` was killed before it released its
  # lease, and its background renewer kept the lease alive for 50 minutes. Two
  # such leases held every `pulls` slot on the token.

  @broker Path.expand("../../../priv/github_guard/gh/40-broker.sh", __DIR__)

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur-lease-renewer")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    %{renewals: Path.join(dir, "renewals")}
  end

  test "the renewer stops when the call that owns the lease is killed", %{renewals: renewals} do
    run_owner(renewals, "kill -9 $$")

    Process.sleep(3_500)
    assert renewal_count(renewals) == 0
  end

  test "the renewer keeps a live call's lease renewed", %{renewals: renewals} do
    run_owner(renewals, "sleep 2.5; budget_stop_renewal")

    assert renewal_count(renewals) >= 1
  end

  defp run_owner(renewals, then_do) do
    script = """
    . "$1"
    budget_command() { echo renew >> "$RENEWALS"; }
    budget_lease=lease-1
    budget_lease_ttl_ms=3000
    budget_start_renewal
    #{then_do}
    """

    System.cmd("sh", ["-c", script, "sh", @broker], env: [{"RENEWALS", renewals}], stderr_to_stdout: true)
  end

  defp renewal_count(path) do
    case File.read(path) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> length()
      _missing -> 0
    end
  end
end
