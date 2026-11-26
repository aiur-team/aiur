defmodule Aiur.AgentWorkpadProgressTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentWorkpadProgress

  test "maps checked workpad steps into the current phase band and names next step" do
    progress =
      AgentWorkpadProgress.parse("""
      ## Agent Workpad
      - Phase: work
      - [x] Inspect the existing event path
      - [x] Add status projection
      - [ ] Write reducer tests
      """)

    assert progress == %{
             percent: 51,
             step: "Write reducer tests",
             phase: "work",
             source: "checklist",
             done: 2,
             total: 3
           }
  end

  test "returns nil when there is no workpad checklist" do
    assert AgentWorkpadProgress.parse("## Notes\n- [ ] arbitrary todo") == nil
  end

  test "bounds the exposed step and defaults an absent phase to work" do
    progress = AgentWorkpadProgress.parse("## Agent Workpad\n- [ ] #{String.duplicate("x", 140)}")

    assert progress.phase == "work"
    assert String.length(progress.step) == 120
  end
end
