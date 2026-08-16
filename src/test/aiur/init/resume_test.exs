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

  test "saved_summary_lines lists a configured bot_account after the repo" do
    config = %{
      "tracker" => %{
        "kind" => "github",
        "github" => %{"repo" => "owner/repo", "bot_account" => "its-applekid"}
      },
      "agent" => %{"kind" => "claude"}
    }

    lines = Resume.saved_summary_lines(config)
    assert "bot_account: its-applekid" in lines

    assert Enum.find_index(lines, &(&1 == "repo: owner/repo")) <
             Enum.find_index(lines, &(&1 == "bot_account: its-applekid"))
  end

  test "format_routing renders sorted maps and blanks non-maps" do
    assert Resume.format_routing(%{2 => "codex", 1 => "claude"}) == "1:claude, 2:codex"
    assert Resume.format_routing(nil) == ""
  end

  test "tracker_from_config reads github, linear, and other trackers" do
    deps = %{detect_repo: fn -> "detected/repo" end}

    error =
      assert_raise ArgumentError, fn ->
        Resume.tracker_from_config(deps, %{"tracker" => %{"kind" => "github"}}, config_path: "/tmp/resumed-aiur-config")
      end

    assert error.message =~ "/tmp/resumed-aiur-config"

    assert Resume.tracker_from_config(deps, %{
             "tracker" => %{
               "base_branch" => "develop",
               "kind" => "github",
               "github" => %{"repo" => "owner/repo", "label_prefix" => "team"}
             }
           }) == %{kind: "github", repo: "owner/repo", label_prefix: "team", base_branch: "develop"}

    assert Resume.tracker_from_config(deps, %{
             "tracker" => %{
               "kind" => "linear",
               "base_branch" => "develop",
               "linear" => %{"api_key" => "key", "project_slug" => "slug"}
             }
           }) == %{kind: "linear", api_key: "key", project_slug: "slug", base_branch: "develop"}

    assert Resume.tracker_from_config(deps, %{"tracker" => %{"kind" => "memory", "base_branch" => "develop"}}) ==
             %{kind: "memory", base_branch: "develop"}
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

  describe "elevenlabs voice input" do
    test "the saved summary reports only whether a key is set, never its value" do
      config = %{
        "tracker" => %{"kind" => "github"},
        "agent" => %{"kind" => "claude"},
        "elevenlabs" => %{"api_key" => "sk-super-secret", "language_code" => "eng"}
      }

      lines = Resume.saved_summary_lines(config)

      assert "elevenlabs_voice_input: api_key set" in lines
      refute Enum.any?(lines, &(&1 =~ "sk-super-secret"))

      assert "elevenlabs_voice_input: api_key not set" in Resume.saved_summary_lines(%{"tracker" => %{}, "agent" => %{}, "elevenlabs" => %{"language_code" => "eng"}})

      refute Enum.any?(
               Resume.saved_summary_lines(%{"tracker" => %{}, "agent" => %{}}),
               &(&1 =~ "elevenlabs")
             )
    end

    test "the section is offered when the config lacks it and skipped when present" do
      assert Resume.missing_section?(%{"prewarm" => %{}}, "elevenlabs")
      refute Resume.missing_section?(%{"elevenlabs" => %{"api_key" => "$ELEVENLABS_API_KEY"}}, "elevenlabs")

      section = Enum.find(Resume.promptable_sections(), &(&1.key == "elevenlabs"))

      assert section.label == "ElevenLabs voice input"
      assert section.opted_in?.(%{enabled: true, api_key: "$ELEVENLABS_API_KEY"})
      refute section.opted_in?.(%{enabled: false, api_key: nil})

      yaml = section.to_yaml.(%{enabled: true, api_key: "$ELEVENLABS_API_KEY"}) |> IO.iodata_to_binary()

      assert yaml =~ "elevenlabs:\n"
      assert yaml =~ "api_key: $ELEVENLABS_API_KEY"
      assert :ok = section.first_run.(nil, nil, nil, nil, %{enabled: true, api_key: nil})
    end

    test "backfill offers the missing section and appends the rendered block" do
      test_pid = self()

      io = %{
        confirm: fn _question, _default -> true end,
        input: fn _label, default, _mask -> default end,
        puts: fn _message -> :ok end
      }

      deps = %{
        append_config: fn target, yaml ->
          send(test_pid, {:appended, target, IO.iodata_to_binary(yaml)})
          {:ok, target}
        end
      }

      sections = Enum.filter(Resume.promptable_sections(), &(&1.key == "elevenlabs"))
      section = hd(sections)

      Resume.offer_section(io, deps, :repo_local, %{}, "/tmp/aiur-config", section)

      assert_received {:appended, "/tmp/aiur-config", yaml}
      assert yaml =~ "api_key: $ELEVENLABS_API_KEY"
      assert yaml =~ "language_code: eng"
    end

    test "declining the offer appends nothing" do
      test_pid = self()

      io = %{
        confirm: fn _question, _default -> false end,
        input: fn _label, default, _mask -> default end,
        puts: fn _message -> :ok end
      }

      deps = %{
        append_config: fn target, yaml ->
          send(test_pid, {:appended, target, IO.iodata_to_binary(yaml)})
          {:ok, target}
        end
      }

      section = Enum.find(Resume.promptable_sections(), &(&1.key == "elevenlabs"))

      Resume.offer_section(io, deps, :repo_local, %{}, "/tmp/aiur-config", section)

      refute_received {:appended, _target, _yaml}

      # The declined answer also renders nothing, so a config written by fresh
      # setup stays free of the section and stays offerable.
      assert IO.iodata_to_binary(section.to_yaml.(%{enabled: false, api_key: nil})) == ""
    end
  end
end
