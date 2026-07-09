defmodule Aiur.Init.QuestionsTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.Questions

  test "normalize_int_or_none accepts none aliases, integers, and invalid values" do
    assert Questions.normalize_int_or_none("none") == :none
    assert Questions.normalize_int_or_none("") == :none
    assert Questions.normalize_int_or_none("unlimited") == :none
    assert Questions.normalize_int_or_none("12") == 12
    assert Questions.normalize_int_or_none("0") == :invalid
    assert Questions.normalize_int_or_none("abc") == :invalid
  end

  test "routing_value encodes backend, model, and effort combinations" do
    assert Questions.routing_value("codex", nil, nil) == "codex"
    assert Questions.routing_value("codex", "gpt-5", nil) == "codex:gpt-5"
    assert Questions.routing_value("codex", nil, "high") == "codex::high"
    assert Questions.routing_value("codex", "gpt-5", "high") == "codex:gpt-5:high"
  end

  test "agent_kinds sorts by routing order and dedups" do
    assert Questions.agent_kinds(["codex", "claude", "codex"]) == ["claude", "codex"]
  end

  test "agent_kind_choices filters to known CLI-backed kinds" do
    choices = Questions.agent_kind_choices()

    assert "claude" in choices
    assert "codex" in choices
    refute "claude-repl" in choices
    assert Enum.all?(choices, &(&1 in Questions.known_agent_kinds()))
  end

  test "primary_kind follows agent ordering" do
    assert Questions.primary_kind(["codex", "claude"]) == "claude"
  end

  test "workspace_default scopes GitHub repos and falls back globally" do
    assert Questions.workspace_default(%{kind: "github", repo: "owner/repo"}) == "~/.aiur/workspaces/owner/repo"
    assert Questions.workspace_default(%{kind: "github", repo: ""}) == "~/.aiur/workspaces"
    assert Questions.workspace_default(%{kind: "linear"}) == "~/.aiur/workspaces"
  end
end
