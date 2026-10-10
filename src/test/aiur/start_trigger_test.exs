defmodule Aiur.StartTriggerTest do
  use ExUnit.Case, async: true
  alias Aiur.StartTrigger
  alias Aiur.StartTrigger.Evidence
  @opts [now_ms: 10_000, max_age_ms: 1_000]

  test "each label stage satisfies exactly the reached triggers" do
    for {label, stage, reached} <- [
          {"ci-wait", :pr_opened, [:pr_opened]},
          {"human-review", :pr_ci_green, [:pr_opened, :pr_ci_green]},
          {"rework", :pr_ci_green, [:pr_opened, :pr_ci_green]},
          {"merging", :pr_approved, [:pr_opened, :pr_ci_green, :pr_approved]},
          {"done", :pr_merged, [:pr_opened, :pr_ci_green, :pr_approved, :pr_merged]}
        ] do
      evidence = evidence(state_label: label)

      for trigger <- StartTrigger.triggers() do
        expected = if trigger in reached, do: {:satisfied, if(stage == :pr_merged, do: :final, else: :optimistic)}, else: :pending
        assert StartTrigger.edge_verdict(trigger, evidence, @opts) == expected
      end

      assert StartTrigger.stage(evidence) == stage
    end
  end

  test "merge releases the default but issue_closed still needs closure" do
    merged = evidence(pr: :merged)
    assert StartTrigger.edge_verdict(:pr_merged, merged, @opts) == {:satisfied, :final}
    assert StartTrigger.edge_verdict(:issue_closed, merged, @opts) == :pending
    assert StartTrigger.final?(merged)
    closed = evidence(issue_open?: false, state_reason: "completed")
    assert StartTrigger.edge_verdict(:issue_closed, closed, @opts) == {:satisfied, :final}
  end

  test "stale missing unknown and future evidence never satisfies any trigger" do
    for trigger <- StartTrigger.triggers(), row <- [nil, evidence(issue_open?: :unknown), evidence(observed_at_ms: nil), evidence(observed_at_ms: 8_999), evidence(observed_at_ms: 10_001)] do
      assert StartTrigger.edge_verdict(trigger, row, @opts) == {:unknown, :stale}
    end
  end

  test "closed unmerged PR and error beat optimistic evidence under every trigger" do
    for trigger <- StartTrigger.triggers() do
      assert StartTrigger.edge_verdict(trigger, evidence(pr: :closed_unmerged, state_label: "done"), @opts) == {:failed, :pr_closed_unmerged}
      assert StartTrigger.edge_verdict(trigger, evidence(state_label: "error", stage_reached: :pr_merged), @opts) == {:failed, :agent_error}
    end
  end

  test "retained stage supplements labels and an open PR alone does not prove readiness" do
    assert StartTrigger.edge_verdict(:pr_ci_green, evidence(state_label: "in-progress", stage_reached: :pr_ci_green), @opts) == {:satisfied, :optimistic}
    assert StartTrigger.edge_verdict(:pr_opened, evidence(pr: :open), @opts) == :pending
    assert StartTrigger.edge_verdict(:pr_opened, evidence(), @opts) == :pending
    refute StartTrigger.final?(nil)
    refute StartTrigger.final?(evidence(pr: :open))
  end

  test "closure policies preserve causes and precedence" do
    row = evidence(issue_open?: false, state_reason: "not_planned")
    assert StartTrigger.edge_verdict(:pr_opened, row, @opts) == {:failed, :not_planned}
    assert StartTrigger.edge_verdict(:pr_opened, row, @opts ++ [not_planned: :satisfy]) == {:satisfied, :final}
    assert StartTrigger.edge_verdict(:pr_opened, evidence(issue_open?: false, state_reason: "duplicate"), @opts) == {:unknown, :duplicate}
    assert StartTrigger.edge_verdict(:pr_opened, evidence(issue_open?: false), @opts) == {:unknown, :closed_reason}
    assert StartTrigger.edge_verdict(:pr_opened, evidence(), @opts ++ [cyclic: true]) == {:unknown, :cyclic}
    assert StartTrigger.edge_verdict(:pr_opened, evidence(unavailable_reason: :closed_reason), @opts) == {:unknown, :closed_reason}
  end

  test "parse accepts only the finite trigger set" do
    assert StartTrigger.triggers() == [:issue_closed, :pr_merged, :pr_approved, :pr_ci_green, :pr_opened]

    for trigger <- StartTrigger.triggers() do
      assert StartTrigger.parse(trigger) == {:ok, trigger}
      assert StartTrigger.parse(Atom.to_string(trigger)) == {:ok, trigger}
    end

    assert StartTrigger.parse("soon") == {:error, :invalid_start_trigger}
    assert StartTrigger.parse(nil) == {:error, :invalid_start_trigger}
  end

  defp evidence(opts \\ []), do: struct!(%Evidence{issue_open?: true, observed_at_ms: 10_000}, opts)
end
