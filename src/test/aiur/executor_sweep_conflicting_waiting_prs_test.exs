defmodule Aiur.ExecutorSweep.ConflictingWaitingPrsTest do
  use ExUnit.Case, async: true

  alias Aiur.ExecutorSweep.Checks

  test "names fresh conflicting PRs that strand waiting tickets" do
    snapshot = %{
      tickets: [%{number: 5267, labels: ["agent:ci-wait"]}, %{number: 5268, labels: ["agent:human-review"]}],
      pull_requests: [
        %{number: 5172, issue_number: 5267, state: "open", mergeable: "CONFLICTING"},
        %{number: 5173, issue_number: 5268, state: "open", mergeable: "CONFLICTING"}
      ],
      github_cache_ages: %{pull_requests: %{5172 => 0, 5173 => 0}}
    }

    findings = Checks.all(snapshot, ~U[2026-10-19 12:00:00Z])

    assert [%{kind: "conflicting_waiting_pr", ticket: 5267, pull_request: 5172, message: message, action: action}, %{kind: "conflicting_waiting_pr", ticket: 5268, pull_request: 5173}] = findings
    assert message =~ "cached mergeable=CONFLICTING"
    assert action =~ "Merge main"
  end

  test "stale cached conflict is unverified and names the cached field" do
    snapshot = %{
      tickets: [%{number: 5267, labels: ["agent:ci-wait"]}],
      pull_requests: [%{number: 5172, issue_number: 5267, state: "open", mergeable: "CONFLICTING"}],
      github_cache_ages: %{pull_requests: %{5172 => 900_000}}
    }

    assert [finding] = Checks.all(snapshot, ~U[2026-10-19 12:00:00Z]) |> Enum.filter(&(&1.kind == "conflicting_waiting_pr"))
    assert finding.cache_age_ms == 900_000
    assert finding.message =~ "unverified (cache age 15m)"
    assert finding.action =~ "Verify the PR"
  end

  test "conflict without a recorded cache age is unverified with unknown age" do
    snapshot = %{
      tickets: [%{number: 5267, labels: ["agent:ci-wait"]}],
      pull_requests: [%{number: 5172, issue_number: 5267, state: "open", mergeable: "CONFLICTING"}]
    }

    assert [finding] = Checks.all(snapshot, ~U[2026-10-19 12:00:00Z]) |> Enum.filter(&(&1.kind == "conflicting_waiting_pr"))
    assert finding.cache_age_ms == nil
    assert finding.message =~ "unverified (cache age unknown)"
    assert finding.action =~ "Verify the PR mergeability in GitHub"
  end
end
