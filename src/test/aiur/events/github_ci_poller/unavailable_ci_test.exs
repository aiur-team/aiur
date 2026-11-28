defmodule Aiur.Events.GithubCIPoller.UnavailableCITest do
  # open-games has hosted Actions off for billing, so its `required` check fails
  # on every head without running, and a host loop is the real CI. #626 was
  # reworked three times for PR #628 on that refusal.
  use ExUnit.Case, async: true

  alias Aiur.CI.FailureDigest
  alias Aiur.Events.GithubCIPoller.UnavailableCI

  @billing "The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the 'Billing & plans' section in your settings"

  defp failed(results),
    do: %{
      decision: :failed,
      pr_number: 628,
      head_sha: "89923a0",
      failures: Enum.map(results, fn {name, result} -> %{name: name, kind: "check_run", result: result, excerpt: nil, started_at: "2026-11-17T06:42:19Z", completed_at: "2026-11-17T06:42:22Z"} end)
    }

  defp digest(errors_by_check) do
    checks = Enum.map(errors_by_check, fn {name, errors} -> %{name: name, url: nil, tests: [], errors: errors, flake_only: false} end)
    fn "89923a0", _opts -> {:ok, %FailureDigest{checks: checks}} end
  end

  defp opts(errors_by_check), do: [ci_failed_rework: true, ci_failure_digest: digest(errors_by_check)]

  test "a check GitHub refused to start for billing is pending, not a rework" do
    assert %{decision: :pending, pending_reason: :ci_not_started, failures: []} =
             UnavailableCI.settle(failed([{"required", "failure"}]), opts([{"required", [@billing]}]))
  end

  test "startup failures are pending without reading annotations" do
    no_digest = [ci_failed_rework: true, ci_failure_digest: fn _, _ -> flunk("read annotations") end]
    assert %{decision: :pending, pending_reason: :ci_not_started} = UnavailableCI.settle(failed([{"build", "startup_failure"}]), no_digest)
  end

  test "a failure that ran or left a summary is real without reading annotations" do
    no_digest = [ci_failed_rework: true, ci_failure_digest: fn _, _ -> flunk("read annotations") end]
    [check] = failed([{"lint", "failure"}]).failures
    long = %{failed([]) | failures: [%{check | completed_at: "2026-11-17T06:44:22Z"}]}
    summarized = %{failed([]) | failures: [%{check | excerpt: "3 errors"}]}

    assert ^long = UnavailableCI.settle(long, no_digest)
    assert ^summarized = UnavailableCI.settle(summarized, no_digest)
  end

  test "a real failure beside a refused check still fails, and quoted errors stay" do
    result = failed([{"required", "failure"}, {"lint", "failure"}])
    assert ^result = UnavailableCI.settle(result, opts([{"required", [@billing]}, {"lint", ["src/app.ts:4 unused import"]}]))

    mixed_lines = failed([{"required", "failure"}])
    assert ^mixed_lines = UnavailableCI.settle(mixed_lines, opts([{"required", [@billing, "test failed: blobs"]}]))
  end

  test "agent.ci_failed_rework: false keeps every failure from reworking" do
    assert %{decision: :pending, pending_reason: :ci_failed_rework_disabled} =
             UnavailableCI.settle(failed([{"lint", "failure"}]), ci_failed_rework: false)
  end

  test "non-failed results pass through untouched" do
    pending = %{decision: :pending, pending_reason: :check_runs_incomplete, failures: []}
    assert ^pending = UnavailableCI.settle(pending, ci_failed_rework: false)
  end
end
