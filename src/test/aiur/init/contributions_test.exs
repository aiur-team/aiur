defmodule Aiur.Init.ContributionsTest do
  use ExUnit.Case, async: false

  alias Aiur.Init.{Contributions, Resume, Templates}

  defmodule Before do
    def init_contribution, do: contribution(:before)

    def contribution(id) do
      %{
        id: id,
        prompt: fn _io, _deps, _location ->
          Process.put(:init_steps, Process.get(:init_steps, []) ++ [id])
          %{enabled: true}
        end,
        yaml: fn _answer -> "#{id}: true\n" end,
        resume: fn _config -> "#{id}: saved" end,
        backfill: fn -> %{key: to_string(id)} end
      }
    end
  end

  defmodule After do
    def init_contribution, do: Before.contribution(:after)
  end

  setup do
    keys = [:init_contributions, :voice_provider]
    saved = Enum.map(keys, &{&1, Application.fetch_env(:aiur, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:aiur, key, value)
        {key, :error} -> Application.delete_env(:aiur, key)
      end)
    end)

    :ok
  end

  test "fresh wizard executes registered prompts and persists sections in order" do
    dir = Path.join(System.tmp_dir!(), "init-contributions-#{System.unique_integer([:positive])}")
    target = Path.join([dir, ".aiur", "config"])
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    Application.put_env(:aiur, :init_contributions, [Before, Aiur.Voice, After])
    original_io = Aiur.InitCase.io(self(), Aiur.InitCase.github_answers())

    io = %{
      original_io
      | confirm: fn question, default ->
          if String.contains?(question, "ElevenLabs"), do: Process.put(:init_steps, Process.get(:init_steps, []) ++ [:elevenlabs])
          original_io.confirm.(question, default)
        end
    }

    deps = Aiur.InitCase.deps(self(), dir, target)
    assert :ok = Aiur.Init.run(%{force: false}, io, deps)
    assert Process.get(:init_steps) == [:before, :elevenlabs, :after]
    yaml = File.read!(target)
    assert yaml =~ ~r/before: true.*elevenlabs:.*after: true/s
  end

  test "registered contributions preserve prompt, YAML, summary and backfill order" do
    Application.put_env(:aiur, :init_contributions, [Before, Aiur.Voice, After])

    io = %{
      confirm: fn question, false ->
        Process.put(:init_steps, Process.get(:init_steps, []) ++ [:elevenlabs])
        assert question == "Enable Stream Deck voice input with ElevenLabs speech-to-text?"
        false
      end
    }

    answers = Contributions.prompt(io, %{}, :repo_local)
    assert Process.get(:init_steps) == [:before, :elevenlabs, :after]
    assert answers.elevenlabs == %{enabled: false, api_key: nil}

    yaml = Templates.build_fills(data(answers))["{{ELEVENLABS_SECTION}}"]
    assert yaml == "\nbefore: true\n\n# === Voice input and playback (declined in `aiur init`; ElevenLabs) ===\nelevenlabs:\n  enabled: false\n\nafter: true\n"
    assert Enum.map(Resume.promptable_sections(), & &1.key) == ["prewarm", "before", "elevenlabs", "after"]
    lines = Resume.saved_summary_lines(%{"elevenlabs" => %{"enabled" => false}})
    assert Enum.take(lines, -3) == ["before: saved", "elevenlabs_voice_input: declined", "after: saved"]
  end

  test "empty registry omits voice questions, backfill, saved summary and YAML even with old answer data" do
    Application.put_env(:aiur, :init_contributions, [])
    assert Contributions.prompt(%{}, %{}, :repo_local) == %{}
    assert Enum.map(Resume.promptable_sections(), & &1.key) == ["prewarm"]
    refute Enum.any?(Resume.saved_summary_lines(%{"elevenlabs" => %{"enabled" => true}}), &String.contains?(&1, "elevenlabs"))
    fills = Templates.build_fills(data(%{}) |> Map.put(:elevenlabs, %{enabled: true, api_key: "$ELEVENLABS_API_KEY"}))
    rendered = Templates.fill_template(Templates.config_example(), fills)
    refute rendered =~ "elevenlabs:"
    refute rendered =~ "{{ELEVENLABS_SECTION}}"
  end

  test "registered voice contributes nothing without an installed provider" do
    Application.put_env(:aiur, :voice_provider, nil)
    assert Contributions.registered!() == []
    assert Contributions.prompt(%{}, %{}, :repo_local) == %{}
    assert Templates.build_fills(data(%{}))["{{ELEVENLABS_SECTION}}"] == ""
  end

  test "missing registry fails before init prompts or filesystem effects" do
    Application.delete_env(:aiur, :init_contributions)
    assert catch_error(Aiur.Init.run(%{force: true}, %{}, %{})) == {:error, :init_contributions_unregistered}
    assert catch_error(Templates.build_fills(data(%{}))) == {:error, :init_contributions_unregistered}
    assert catch_error(Resume.promptable_sections()) == {:error, :init_contributions_unregistered}
  end

  defp data(answers) do
    %{
      tracker: %{kind: "github", repo: "owner/repo", base_branch: "main"},
      agents: ["codex"],
      routing: Map.new(1..5, &{&1, "codex"}),
      permission_mode: "bypassPermissions",
      workspace_root: "~/.aiur/workspaces",
      max_agents: 1,
      max_turns: "none",
      max_duration: 60,
      pre_warmed: 0,
      polling: 120,
      prompt_file: "prompt.md",
      prewarm: %{enabled: false},
      alerts: %{enabled: false, use_os_default_sounds: false},
      contributions: answers
    }
  end
end
