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
    %{renewals: Path.join(dir, "renewals"), renewer_pid_file: Path.join(dir, "renewer.pid")}
  end

  test "the renewer stops when the call that owns the lease is killed", %{renewals: renewals, renewer_pid_file: pid_file} do
    run_owner(renewals, "printf '%s\\n' \"$budget_renewal_pid\" > \"$RENEWER_PID_FILE\"; kill -9 $$", pid_file)

    renewer_pid = String.trim(File.read!(pid_file))
    assert String.match?(renewer_pid, ~r/\A\d+\z/)
    assert :ok = wait_for_renewer_exit(renewer_pid)
    assert renewal_count(renewals) == 0
  end

  test "the renewer keeps a live call's lease renewed", %{renewals: renewals} do
    run_owner(renewals, "sleep 2.5; budget_stop_renewal")

    assert renewal_count(renewals) >= 1
  end

  defp run_owner(renewals, then_do, pid_file \\ nil) do
    script = """
    . "$1"
    budget_command() { echo renew >> "$RENEWALS"; }
    budget_lease=lease-1
    budget_lease_ttl_ms=3000
    budget_start_renewal
    #{then_do}
    """

    env = [{"RENEWALS", renewals}]
    env = if pid_file, do: [{"RENEWER_PID_FILE", pid_file} | env], else: env
    System.cmd("sh", ["-c", script, "sh", @broker], env: env, stderr_to_stdout: true)
  end

  defp wait_for_renewer_exit(pid) do
    script = """
    pid=$1
    attempts=0
    while kill -0 "$pid" 2>/dev/null; do
      [ "$attempts" -lt 100 ] || exit 1
      attempts=$((attempts + 1))
      sleep 0.05
    done
    """

    case System.cmd("sh", ["-c", script, "sh", String.trim(pid)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {status, output}}
    end
  end

  defp renewal_count(path) do
    case File.read(path) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> length()
      _missing -> 0
    end
  end
end
