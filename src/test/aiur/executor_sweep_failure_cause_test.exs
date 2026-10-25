defmodule Aiur.ExecutorSweep.FailureCauseTest do
  use ExUnit.Case, async: true

  alias Aiur.ExecutorSweep.Checks

  test "classifies red required checks from matching base evidence" do
    now = ~U[2026-10-18 14:00:00Z]

    pr = %{
      number: 5018,
      state: "open",
      review_decision: "APPROVED",
      head_sha: "head",
      ci_head_sha: "head",
      ci_observed_at_ms: DateTime.to_unix(now, :millisecond),
      base_sha: "base-sha",
      approved_head_sha: "head",
      in_merge_queue: false,
      auto_merge: false,
      required_checks: [%{name: "test", conclusion: "failure"}]
    }

    findings = fn pull_request, base_checks ->
      Checks.all(
        %{pull_requests: [pull_request], base_checks: base_checks, github_cache_ages: %{pull_requests: %{5018 => 0}}},
        now
      )
      |> Enum.filter(&(&1.kind == "approved_pr_red"))
    end

    assert [%{failure_class: "unknown"}] = findings.(pr, [])

    assert [%{failure_class: "unknown"}] =
             findings.(pr, [%{name: "test", base_sha: "other-base", conclusion: "success"}])

    assert [%{failure_class: "caused_by_pr", message: pr_caused_message}] =
             findings.(pr, [%{name: "test", base_sha: "base-sha", conclusion: "success"}])

    assert pr_caused_message =~ "test (PR-caused)"

    assert [%{failure_class: "inherited", message: inherited_message}] =
             findings.(pr, [%{name: "test", base_sha: "base-sha", conclusion: "failure"}])

    assert inherited_message =~ "test (inherited)"

    assert [%{failure_class: "infra", message: infra_message}] =
             findings.(%{pr | required_checks: [%{name: "test", conclusion: "timed_out"}]}, [])

    assert infra_message =~ "test (infra)"
  end
end
