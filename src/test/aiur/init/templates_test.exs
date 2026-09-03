defmodule Aiur.Init.TemplatesTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.{ElevenLabs, Resume, Templates}

  test "embedded templates return non-empty content" do
    assert Templates.config_example() =~ "tracker:"
    assert Templates.config_example() =~ "host omitted = authenticated Tailscale IP"
    assert Templates.config_example() =~ "add host: 127.0.0.1 to pin loopback"
    assert Templates.aiurhooks_template() =~ "after_create:"
    assert Templates.aiurhooks_template() =~ "AIUR_TICKET_BRANCH"
    assert Templates.aiurhooks_template() =~ "origin/$AIUR_TICKET_BRANCH"

    assert Templates.aiurhooks_template() =~
             ~s|git update-ref refs/aiur/branch-start "$(git merge-base "origin/$base_branch" HEAD)"|

    assert Templates.aiurhooks_template() =~ "Aiur must stage incomplete workspace reconstruction"
    refute Templates.aiurhooks_template() =~ "find . -mindepth 1 -maxdepth 1 -exec rm -rf"
    assert Templates.prompt_file_template() =~ "{{REPO}}"
    prompt = Templates.prompt_file_template()

    assert prompt =~ "explicit signal as readiness to consume"
    assert prompt =~ "latest `ticket.N.branch.push` payload only to fetch and diff the actual validated ref"
    assert prompt =~ "Never infer readiness from `branch.push` alone"
    assert prompt =~ ~s(aiur guard-pr-deletions "$AIUR_BASE_BRANCH")
    assert prompt =~ "more than 50 files the feature never touched would be deleted"

    handoff = Templates.executor_handoff_template()

    for section <- [
          "Identity and credentials",
          "Operator non-negotiables",
          "Current state (packs, versions, dashboard)",
          "Live work and PRs needing attention",
          "Environment hazards measured this run",
          "Known dispatch failure modes",
          "What to do next, ranked"
        ] do
      assert handoff =~ "## " <> section
    end

    assert Templates.env_content() == "GITHUB_TOKEN=\n"
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
        tracker: %{kind: "github", repo: "owner/repo", base_branch: "develop"},
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
        alerts: %{enabled: true, use_os_default_sounds: false},
        elevenlabs: %{enabled: false, api_key: nil}
      })

    rendered =
      Templates.fill_template(
        "{{TRACKER_KIND}} {{BASE_BRANCH}} {{TRACKER_PROVIDER}} {{AGENT_KIND}} {{ROUTING}} {{PREWARM_BASE_BUILD_FILE}}",
        fills
      )

    assert rendered =~ "github"
    assert rendered =~ "develop"
    assert rendered =~ "repo: owner/repo"
    assert rendered =~ "claude"
    assert rendered =~ "{1: claude, 2: claude, 3: codex, 4: codex:gpt-5, 5: codex:gpt-5:high}"
    assert rendered =~ "base_build_file: prewarm"
  end

  test "build_fills renders github bot_account when present and omits it when blank" do
    base = %{
      agents: ["claude"],
      routing: %{1 => "claude", 2 => "claude", 3 => "claude", 4 => "claude", 5 => "claude"},
      permission_mode: "bypassPermissions",
      workspace_root: "~/.aiur/workspaces/owner/repo",
      max_agents: 1,
      max_turns: "none",
      max_duration: 60,
      pre_warmed: 0,
      polling: 30,
      prompt_file: "prompt.md",
      prewarm: %{enabled: false},
      alerts: %{enabled: false, use_os_default_sounds: false},
      elevenlabs: %{enabled: false, api_key: nil}
    }

    with_account =
      Templates.fill_template(
        "{{TRACKER_PROVIDER}}",
        Templates.build_fills(Map.put(base, :tracker, %{kind: "github", repo: "owner/repo", bot_account: "its-applekid", base_branch: "develop"}))
      )

    assert with_account =~ "repo: owner/repo"
    assert with_account =~ "bot_account: its-applekid"

    without_account =
      Templates.fill_template(
        "{{TRACKER_PROVIDER}}",
        Templates.build_fills(Map.put(base, :tracker, %{kind: "github", repo: "owner/repo", bot_account: nil, base_branch: "develop"}))
      )

    refute without_account =~ "bot_account:"
  end

  test "build_fills YAML-quotes branch names with scalar-like values" do
    base = %{
      agents: ["codex"],
      routing: %{1 => "codex", 2 => "codex", 3 => "codex", 4 => "codex", 5 => "codex"},
      permission_mode: "bypassPermissions",
      workspace_root: "/tmp/workspaces",
      max_agents: 1,
      max_turns: "none",
      max_duration: 60,
      pre_warmed: 0,
      polling: 30,
      prompt_file: "prompt.md",
      prewarm: %{enabled: false},
      alerts: %{enabled: false, use_os_default_sounds: false},
      elevenlabs: %{enabled: false, api_key: nil}
    }

    for branch <- ["false", "null", "123"] do
      fills = Templates.build_fills(Map.put(base, :tracker, %{kind: "github", repo: "owner/repo", base_branch: branch}))
      rendered = Templates.fill_template("tracker:\n  base_branch: {{BASE_BRANCH}}\n", fills)

      assert {:ok, %{"tracker" => %{"base_branch" => ^branch}}} = YamlElixir.read_from_string(rendered)
    end
  end

  test "build_fills writes the ordered priority list" do
    fills =
      Templates.build_fills(%{
        tracker: %{kind: "github", repo: "owner/repo", base_branch: "develop"},
        agents: ["codex", "claude"],
        routing: %{1 => "claude", 2 => "claude", 3 => "claude", 4 => "claude", 5 => "claude"},
        permission_mode: "bypassPermissions",
        workspace_root: "~/.aiur/workspaces/owner/repo",
        max_agents: 1,
        max_turns: "none",
        max_duration: 60,
        pre_warmed: 0,
        polling: 30,
        prompt_file: "prompt.md",
        prewarm: %{enabled: false},
        alerts: %{enabled: false, use_os_default_sounds: false},
        elevenlabs: %{enabled: false, api_key: nil}
      })

    assert Templates.fill_template("{{PRIORITY}}", fills) == "[codex, claude]"
  end

  describe "elevenlabs voice-input section" do
    test "opting in fills the whole section from the shared renderer" do
      rendered = render_elevenlabs(%{enabled: true, api_key: "$ELEVENLABS_API_KEY"})

      assert {:ok,
              %{
                "elevenlabs" => %{
                  "enabled" => true,
                  "api_key" => "$ELEVENLABS_API_KEY",
                  "language_code" => "eng",
                  "voice_id" => nil
                }
              }} =
               YamlElixir.read_from_string(rendered)

      assert rendered ==
               "\n" <> IO.iodata_to_binary(ElevenLabs.eleven_labs_section_yaml(%{enabled: true, api_key: "$ELEVENLABS_API_KEY"}))
    end

    test "declining renders a valid disabled section" do
      rendered = render_elevenlabs(%{enabled: false, api_key: nil})

      assert {:ok, %{"elevenlabs" => %{"enabled" => false}}} = YamlElixir.read_from_string(rendered)
    end

    test "the shipped example renders as valid YAML with the section when opted in" do
      rendered = render_example(%{enabled: true, api_key: "$ELEVENLABS_API_KEY"})

      refute rendered =~ "{{ELEVENLABS_SECTION}}"

      assert {:ok, config} = YamlElixir.read_from_string(rendered)

      assert %{
               "elevenlabs" => %{
                 "enabled" => true,
                 "api_key" => "$ELEVENLABS_API_KEY",
                 "language_code" => "eng",
                 "voice_id" => nil
               }
             } = config
    end

    test "the shipped example records an explicit ElevenLabs decline" do
      rendered = render_example(%{enabled: false, api_key: nil})

      refute rendered =~ "{{ELEVENLABS_SECTION}}"
      refute rendered =~ "\n\n\n"

      assert {:ok, config} = YamlElixir.read_from_string(rendered)
      assert config["elevenlabs"] == %{"enabled" => false}
      refute Resume.missing_section?(config, "elevenlabs")
    end
  end

  defp render_example(answer) do
    Templates.fill_template(Templates.config_example(), elevenlabs_fills(answer))
  end

  defp render_elevenlabs(answer) do
    Templates.fill_template("{{ELEVENLABS_SECTION}}", elevenlabs_fills(answer))
  end

  defp elevenlabs_fills(answer) do
    Templates.build_fills(%{
      tracker: %{kind: "github", repo: "owner/repo", base_branch: "develop"},
      agents: ["claude"],
      routing: %{1 => "claude", 2 => "claude", 3 => "claude", 4 => "claude", 5 => "claude"},
      permission_mode: "bypassPermissions",
      workspace_root: "/tmp/workspaces",
      max_agents: 1,
      max_turns: "none",
      max_duration: 60,
      pre_warmed: 0,
      polling: 30,
      prompt_file: "prompt.md",
      prewarm: %{enabled: false},
      alerts: %{enabled: false, use_os_default_sounds: false},
      elevenlabs: answer
    })
  end
end
