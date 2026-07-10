defmodule Aiur.Init.TemplatesTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.Templates

  test "embedded templates return non-empty content" do
    assert Templates.config_example() =~ "tracker:"
    assert Templates.aiurhooks_template() =~ "after_create:"
    assert Templates.prompt_file_template() =~ "{{REPO}}"
    assert Templates.env_example_content() =~ "GITHUB_TOKEN="
  end

  test "alerts_template selects macOS and Linux bodies" do
    macos = Templates.alerts_template({:unix, :darwin})
    linux = Templates.alerts_template({:unix, :linux})

    assert macos =~ "/System/Library/Sounds/"
    assert linux =~ "/usr/share/sounds/freedesktop/"
    assert Templates.alerts_template({:unix, :freebsd}) == linux
    assert Templates.alerts_template(:unknown) == linux
  end

  test "prompt_file_scaffold fills repo and falls back to current" do
    scaffold = Templates.prompt_file_scaffold("owner/repo")
    nil_scaffold = Templates.prompt_file_scaffold(nil)
    blank_scaffold = Templates.prompt_file_scaffold("  ")

    assert scaffold =~ "owner/repo"
    assert nil_scaffold =~ "current"
    assert blank_scaffold =~ "current"
    refute scaffold =~ "{{REPO}}"
    assert scaffold =~ "{{ issue.title }}"
  end

  test "build_fills and fill_template render a known token map" do
    fills =
      Templates.build_fills(%{
        tracker: %{kind: "github", repo: "owner/repo"},
        agents: ["codex", "claude", "codex"],
        routing: %{1 => "claude", 2 => "claude", 3 => "codex", 4 => "codex:gpt-5", 5 => "codex:gpt-5:high"},
        permission_mode: "bypassPermissions",
        workspace_root: "~/.aiur/workspaces/owner/repo",
        max_agents: 3,
        max_turns: "none",
        max_duration: 60,
        pre_warmed: 2,
        polling: 30,
        prompt_file: "prompt.md",
        prewarm: %{enabled: true, base_build: "mise exec -- mix compile"},
        alerts: %{enabled: true, use_os_default_sounds: false}
      })

    rendered =
      Templates.fill_template(
        "{{TRACKER_KIND}} {{TRACKER_PROVIDER}} {{AGENT_KIND}} {{ROUTING}} {{PREWARM_BASE_BUILD_FILE}}",
        fills
      )

    assert rendered =~ "github"
    assert rendered =~ "repo: owner/repo"
    assert rendered =~ "claude"
    assert rendered =~ "{1: claude, 2: claude, 3: codex, 4: codex:gpt-5, 5: codex:gpt-5:high}"
    assert rendered =~ "base_build_file: prewarm"
  end

  test "build_fills writes the ordered rate-limit fallback when selected" do
    fills =
      Templates.build_fills(%{
        tracker: %{kind: "github", repo: "owner/repo"},
        agents: ["claude", "codex"],
        routing: %{1 => "claude", 2 => "claude", 3 => "claude", 4 => "claude", 5 => "claude"},
        rate_limit_fallback: ["codex", "claude"],
        permission_mode: "bypassPermissions",
        workspace_root: "~/.aiur/workspaces/owner/repo",
        max_agents: 1,
        max_turns: "none",
        max_duration: 60,
        pre_warmed: 0,
        polling: 30,
        prompt_file: "prompt.md",
        prewarm: %{enabled: false},
        alerts: %{enabled: false, use_os_default_sounds: false}
      })

    assert Templates.fill_template("{{RATE_LIMIT_FALLBACK}}", fills) ==
             "  switch_model_on_ratelimit: [codex, claude]\n"
  end
end
