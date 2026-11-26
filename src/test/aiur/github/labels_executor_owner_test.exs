defmodule Aiur.GitHub.LabelsExecutorOwnerTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.Labels

  test "bare owner marker is omitted from init labels but recognized as a marker rather than a state" do
    labels = Labels.label_set("agent", ["codex"])

    refute "agent:executor" in labels
    refute "agent:executor" in Labels.state_labels("agent")
    assert Labels.executor_label_prefix("agent") == "agent:executor:"
    assert Labels.marker_suffix?("executor")
    assert Labels.marker_suffix?("executor:codex")
    refute Labels.marker_suffix?("executorfake")
    refute Labels.marker_suffix?("agent:executor:codex")

    assert Labels.describe("sym:executor:codex") ==
             "Executor-owned by codex: no dispatch, no fleet slot"

    assert Labels.describe("sym:executor") ==
             "Executor-owned by unknown owner: no dispatch, no fleet slot"
  end
end
