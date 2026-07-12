defmodule Aiur.Init.ResumeTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.Resume

  test "saved_summary_lines renders a known config map" do
    config = %{
      "tracker" => %{"kind" => "github", "github" => %{"repo" => "owner/repo"}},
      "agent" => %{
        "kind" => "claude",
        "routing" => %{"1" => "claude", "2" => "codex:gpt-5"},
        "claude" => %{"permission_mode" => "bypassPermissions"},
        "max_concurrent_agents" => 2,
        "max_turns" => "none",
        "max_agent_duration_minutes" => 60
      },
      "workspace" => %{"root" => "~/.aiur/workspaces/owner/repo"},
      "polling" => %{"interval_seconds" => 30},
      "pre_warmed_sessions" => 3,
      "alerts" => %{"enabled" => true},
      "prompt_file" => "prompt.md"
    }

    assert Resume.saved_summary_lines(config) == [
             "tracker: github",
             "repo: owner/repo",
             "agent: claude",
             "routing: 1:claude, 2:codex:gpt-5",
             "permission_mode: bypassPermissions",
             "max_concurrent_agents: 2",
             "max_turns: none",
             "max_agent_duration_minutes: 60",
             "workspace_root: ~/.aiur/workspaces/owner/repo",
             "pre_warmed_sessions: 3",
             "polling_interval_seconds: 30",
             "alerts: true",
             "prompt_file: prompt.md"
           ]
  end

  test "format_routing renders sorted maps and blanks non-maps" do
    assert Resume.format_routing(%{2 => "codex", 1 => "claude"}) == "1:claude, 2:codex"
    assert Resume.format_routing(nil) == ""
  end

  test "tracker_from_config reads github, linear, and other trackers" do
    deps = %{detect_repo: fn -> "detected/repo" end}

    assert Resume.tracker_from_config(deps, %{"tracker" => %{"kind" => "github"}}) ==
             %{kind: "github", repo: "detected/repo", label_prefix: "agent"}

    assert Resume.tracker_from_config(deps, %{
             "tracker" => %{
               "kind" => "github",
               "github" => %{"repo" => "owner/repo", "label_prefix" => "team"}
             }
           }) == %{kind: "github", repo: "owner/repo", label_prefix: "team"}

    assert Resume.tracker_from_config(deps, %{
             "tracker" => %{"kind" => "linear", "linear" => %{"api_key" => "key", "project_slug" => "slug"}}
           }) == %{kind: "linear", api_key: "key", project_slug: "slug"}

    assert Resume.tracker_from_config(deps, %{"tracker" => %{"kind" => "memory"}}) == %{kind: "memory"}
  end

  test "agents_from_config includes routing backends, deduped and sorted" do
    config = %{"agent" => %{"kind" => "codex", "routing" => %{"1" => "claude:sonnet", "2" => "codex:gpt-5"}}}

    assert Resume.agents_from_config(config) == ["claude", "codex"]
  end

  test "routing_backend recovers backend from routing strings" do
    assert Resume.routing_backend("claude:sonnet:high") == "claude"
    assert Resume.routing_backend("codex") == "codex"
  end

  test "alerts_summary_line reports enabled state only when present" do
    assert Resume.alerts_summary_line(%{"alerts" => %{"enabled" => false}}) == "alerts: false"
    assert Resume.alerts_summary_line(%{}) == nil
  end
end
