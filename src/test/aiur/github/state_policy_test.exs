defmodule Aiur.GitHub.StatePolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.StatePolicy

  test "normalizes state names and builds prefixed labels" do
    assert StatePolicy.normalize_state(" Human Review ") == "human-review"
    assert StatePolicy.state_label("agent", "In Progress") == "agent:in-progress"
  end

  test "classifies human-review, active, and terminal states" do
    assert StatePolicy.human_review_target_state?("human review")
    assert StatePolicy.active_target_state?("rework")
    refute StatePolicy.active_target_state?("done")
    assert StatePolicy.terminal_state_name?("cancelled")
    assert StatePolicy.terminal_state_name?("canceled")
    assert StatePolicy.terminal_state_label?("agent:done", "agent")
    refute StatePolicy.terminal_state_label?("agent:paused", "agent")
  end
end
