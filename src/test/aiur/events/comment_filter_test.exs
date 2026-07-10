defmodule Aiur.Events.CommentFilterTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.CommentFilter

  test "detects an Agent Workpad body via string key" do
    assert CommentFilter.agent_workpad?(%{"body" => "## Agent Workpad\n\nnotes"})
  end

  test "ignores leading whitespace before the heading" do
    assert CommentFilter.agent_workpad?(%{"body" => "   \n## Agent Workpad"})
  end

  test "falls back to an atom body key" do
    assert CommentFilter.agent_workpad?(%{body: "## Agent Workpad extras"})
  end

  test "rejects non-workpad comment bodies" do
    refute CommentFilter.agent_workpad?(%{"body" => "just a normal comment"})
  end

  test "treats a comment with no body as non-workpad" do
    refute CommentFilter.agent_workpad?(%{})
  end

  test "treats non-map inputs as non-workpad" do
    refute CommentFilter.agent_workpad?("## Agent Workpad")
    refute CommentFilter.agent_workpad?(nil)
  end
end
