defmodule Aiur.Init.QuestionsTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.Questions

  test "prompt_tracker offers and logs the repository default branch read from the API" do
    parent = self()

    io = %{
      select: fn "Issue tracker", _options, _default -> "github" end,
      input: fn
        "GitHub repo (owner/name)", _default, _hint -> "owner/repo"
        "Tracker base branch", default, _hint -> default
      end,
      puts: fn message -> send(parent, {:puts, message}) end
    }

    deps = %{
      detect_repo: fn -> "owner/repo" end,
      detect_default_branch: fn "owner/repo" -> "develop" end
    }

    assert Questions.prompt_tracker(io, deps, :repo_local) ==
             %{kind: "github", repo: "owner/repo", base_branch: "develop"}

    assert_received {:puts, message}
    assert message =~ "default branch"
    assert message =~ "develop"
  end

  test "prompt_tracker preserves an explicit branch instead of the API default" do
    io = %{
      select: fn "Issue tracker", _options, _default -> "github" end,
      input: fn
        "GitHub repo (owner/name)", _default, _hint -> "owner/repo"
        "Tracker base branch", _default, _hint -> "release"
      end,
      puts: fn _message -> :ok end
    }

    deps = %{
      detect_repo: fn -> "owner/repo" end,
      detect_default_branch: fn "owner/repo" -> "develop" end
    }

    assert Questions.prompt_tracker(io, deps, :repo_local) ==
             %{kind: "github", repo: "owner/repo", base_branch: "release"}
  end

  test "prompt_tracker reads the API default only once while retrying blank answers" do
    parent = self()
    attempts = :atomics.new(1, [])

    io = %{
      select: fn "Issue tracker", _options, _default -> "github" end,
      input: fn
        "GitHub repo (owner/name)", _default, _hint ->
          "owner/repo"

        "Tracker base branch", default, _hint ->
          if :atomics.add_get(attempts, 1, 1) == 1, do: "", else: default
      end,
      puts: fn message -> send(parent, {:puts, message}) end
    }

    deps = %{
      detect_repo: fn -> "owner/repo" end,
      detect_default_branch: fn "owner/repo" ->
        send(parent, :detected_default)
        "develop"
      end
    }

    assert Questions.prompt_tracker(io, deps, :repo_local).base_branch == "develop"
    assert_received :detected_default
    refute_received :detected_default
  end

  test "global tracker setup requires an explicit branch instead of pinning the current repository default" do
    io = %{
      select: fn "Issue tracker", _options, _default -> "github" end,
      input: fn "Tracker base branch", nil, _hint -> "release" end,
      puts: fn _message -> :ok end
    }

    deps = %{
      detect_repo: fn -> flunk("global config must not persist the current repository") end,
      detect_default_branch: fn nil -> nil end
    }

    assert Questions.prompt_tracker(io, deps, :global) ==
             %{kind: "github", repo: nil, base_branch: "release"}
  end

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
