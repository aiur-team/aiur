defmodule Aiur.InitTest do
  use ExUnit.Case, async: true

  alias Aiur.Config
  alias Aiur.Init
  alias Aiur.Workflow

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-init-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp io(parent, inputs \\ []) do
    {:ok, queue} = Agent.start_link(fn -> inputs end)

    %{
      puts: fn message ->
        send(parent, {:puts, IO.chardata_to_string(message)})
        :ok
      end,
      gets: fn _prompt ->
        Agent.get_and_update(queue, fn
          [head | tail] -> {head, tail}
          [] -> {:eof, []}
        end)
      end
    }
  end

  defp deps(dir, overrides \\ %{}) do
    parent = self()

    Map.merge(
      %{
        existing_config_path: fn -> nil end,
        detect_repo: fn -> nil end,
        write_config: fn yaml ->
          path = Path.join(dir, ".aiurconfig")
          File.write!(path, yaml)
          send(parent, {:write, path})
          {:ok, path}
        end,
        ensure_env: fn content ->
          File.write!(Path.join(dir, ".env.example"), content)
          env_path = Path.join(dir, ".env")

          if File.regular?(env_path) do
            {:exists, env_path}
          else
            File.write!(env_path, content)
            {:created, env_path}
          end
        end,
        check_agent_auth: fn _kind -> :ok end,
        check_tracker_auth: fn _tracker -> :ok end,
        create_labels: fn tracker, labels ->
          send(parent, {:labels, tracker, labels})
          :ok
        end
      },
      overrides
    )
  end

  defp written_config(path) do
    assert {:ok, loaded} = Workflow.load(path)
    loaded.config
  end

  describe "existing-config guard (R7)" do
    test "aborts when a config already exists and --force is not passed", %{dir: dir} do
      deps = deps(dir, %{existing_config_path: fn -> "/repo/.aiurconfig" end})

      assert {:error, message} = Init.run(%{force: false}, io(self()), deps)
      assert message =~ ".aiurconfig already exists"
      assert message =~ "--force"
      refute_received {:puts, _}
      refute_received {:write, _}
    end

    test "proceeds when a config exists but --force is passed", %{dir: dir} do
      deps = deps(dir, %{existing_config_path: fn -> "/repo/.aiurconfig" end})

      assert :ok = Init.run(%{force: true}, io(self(), ["memory"]), deps)
      assert_received {:write, _}
    end
  end

  describe "tracker prompts and config assembly (R2, R4, R5, R9)" do
    test "github tracker writes repo, label_prefix, and a starter routing table", %{dir: dir} do
      inputs = ["github", "octo/repo", "team"]
      assert :ok = Init.run(%{force: false}, io(self(), inputs), deps(dir))

      assert_received {:write, path}
      config = written_config(path)

      assert config["tracker"]["kind"] == "github"
      assert config["github"]["repo"] == "octo/repo"
      assert config["github"]["label_prefix"] == "team"
      assert config["agent"]["kind"] == "claude"
      assert config["agent"]["routing"] == %{1 => "claude", 2 => "claude", 3 => "claude", 4 => "claude", 5 => "claude"}
      assert config["agent"]["complexity_prompts"] == %{1 => "", 2 => "", 3 => "", 4 => "", 5 => ""}
    end

    test "github repo prompt pre-fills from the detected remote", %{dir: dir} do
      deps = deps(dir, %{detect_repo: fn -> "me/app" end})
      # Empty repo + prefix inputs accept the detected/default values.
      assert :ok = Init.run(%{force: false}, io(self(), ["github", "", ""]), deps)

      assert_received {:write, path}
      config = written_config(path)
      assert config["github"]["repo"] == "me/app"
      assert config["github"]["label_prefix"] == "aiur"
    end

    test "no git remote leaves repo unset (nil pre-fill)", %{dir: dir} do
      deps = deps(dir, %{detect_repo: fn -> nil end})
      assert :ok = Init.run(%{force: false}, io(self(), ["github", "", ""]), deps)

      assert_received {:write, path}
      config = written_config(path)
      refute Map.has_key?(config["github"], "repo")
    end

    test "linear tracker writes api_key and project_slug", %{dir: dir} do
      inputs = ["linear", "lin_key_123", "team-alpha"]
      assert :ok = Init.run(%{force: false}, io(self(), inputs), deps(dir))

      assert_received {:write, path}
      config = written_config(path)
      assert config["tracker"]["kind"] == "linear"
      assert config["linear"]["api_key"] == "lin_key_123"
      assert config["linear"]["project_slug"] == "team-alpha"
    end

    test "memory tracker writes a minimal config", %{dir: dir} do
      assert :ok = Init.run(%{force: false}, io(self(), ["memory"]), deps(dir))

      assert_received {:write, path}
      config = written_config(path)
      assert config["tracker"]["kind"] == "memory"
      refute Map.has_key?(config, "github")
      refute Map.has_key?(config, "linear")
    end

    test "re-prompts on an unrecognized tracker kind", %{dir: dir} do
      assert :ok = Init.run(%{force: false}, io(self(), ["bogus", "memory"]), deps(dir))
      assert_received {:puts, "Setting up aiur in this repo."}
      assert_received {:puts, message}
      assert message =~ "Please choose one of"
    end
  end

  describe ".env scaffold for the github tracker" do
    test "creates .env from .env.example and prints token steps", %{dir: dir} do
      assert :ok = Init.run(%{force: false}, io(self(), ["github", "octo/repo", "team"]), deps(dir))

      assert File.read!(Path.join(dir, ".env.example")) =~ "GITHUB_TOKEN="
      assert File.read!(Path.join(dir, ".env")) =~ "GITHUB_TOKEN="

      assert_received {:puts, "Setting up aiur in this repo."}
      assert_received {:puts, "Wrote " <> _}
      assert_received {:puts, created}
      assert created =~ "Created"
      assert created =~ ".env"
      assert_received {:puts, set_token}
      assert set_token =~ "Set GITHUB_TOKEN"
      assert_received {:puts, url}
      assert url =~ "https://github.com/settings/tokens"
    end

    test "leaves an existing .env untouched", %{dir: dir} do
      env_path = Path.join(dir, ".env")
      File.write!(env_path, "GITHUB_TOKEN=keepme\n")

      assert :ok = Init.run(%{force: false}, io(self(), ["github", "octo/repo", "team"]), deps(dir))

      assert File.read!(env_path) == "GITHUB_TOKEN=keepme\n"
      assert_received {:puts, "Setting up aiur in this repo."}
      assert_received {:puts, "Wrote " <> _}
      assert_received {:puts, found}
      assert found =~ "Found existing"
    end

    test "skips .env scaffold for the memory tracker", %{dir: dir} do
      assert :ok = Init.run(%{force: false}, io(self(), ["memory"]), deps(dir))

      refute File.exists?(Path.join(dir, ".env.example"))
      refute File.exists?(Path.join(dir, ".env"))
    end
  end

  describe "agent selection (U4)" do
    test "re-prompts until at least one known agent is chosen", %{dir: dir} do
      assert :ok = Init.run(%{force: false}, io(self(), ["memory", "bogus", "claude"]), deps(dir))

      assert_received {:puts, "Setting up aiur in this repo."}
      assert_received {:puts, choose}
      assert choose =~ "Please choose at least one"
    end

    test "writes a chosen claude model to the claude section", %{dir: dir} do
      inputs = ["memory", "claude", "sonnet"]
      assert :ok = Init.run(%{force: false}, io(self(), inputs), deps(dir))

      assert_received {:write, path}
      assert written_config(path)["claude"]["model"] == "sonnet"
    end
  end

  describe "background auth checks (U4, R5/R6)" do
    test "stays silent and proceeds when every check passes", %{dir: dir} do
      assert :ok = Init.run(%{force: false}, io(self(), ["memory", "claude", "opus"]), deps(dir))

      assert_received {:write, _}
      refute_received {:puts, "⚠" <> _}
    end

    test "only checks the agents that were chosen", %{dir: dir} do
      parent = self()

      overrides = %{
        check_agent_auth: fn kind ->
          send(parent, {:agent_checked, kind})
          :ok
        end
      }

      assert :ok =
               Init.run(%{force: false}, io(self(), ["memory", "claude", "opus"]), deps(dir, overrides))

      assert_received {:agent_checked, "claude"}
      refute_received {:agent_checked, "codex"}
    end

    test "warns on a failed tracker check but still writes the config (R6)", %{dir: dir} do
      overrides = %{
        check_tracker_auth: fn _tracker -> {:error, "GITHUB_TOKEN not set"} end
      }

      inputs = ["github", "octo/repo", "team"]
      assert :ok = Init.run(%{force: false}, io(self(), inputs), deps(dir, overrides))

      assert_received {:write, _}
      assert_received {:puts, "⚠ github tracker: GITHUB_TOKEN not set"}
    end

    test "retrying a failed check clears the warning once it passes", %{dir: dir} do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      overrides = %{
        check_tracker_auth: fn _tracker ->
          n = Agent.get_and_update(attempts, fn n -> {n, n + 1} end)
          if n == 0, do: {:error, "transient failure"}, else: :ok
        end
      }

      inputs = ["github", "octo/repo", "team", "claude", "opus", "10", "3", "3", "r"]
      assert :ok = Init.run(%{force: false}, io(self(), inputs), deps(dir, overrides))

      assert_received {:puts, "⚠ github tracker: transient failure"}
      refute_received {:puts, "⚠" <> _}
    end
  end

  describe "concurrency prompts (U5)" do
    test "accepting defaults writes the schema concurrency values", %{dir: dir} do
      assert :ok = Init.run(%{force: false}, io(self(), ["memory"]), deps(dir))

      assert_received {:write, path}
      config = written_config(path)
      assert config["agent"]["max_concurrent_agents"] == 10
      assert config["max_vertical_panes"] == 3
      assert config["pre_warmed_sessions"] == 3
    end

    test "custom concurrency values are reflected in the config", %{dir: dir} do
      inputs = ["memory", "claude", "opus", "4", "2", "1"]
      assert :ok = Init.run(%{force: false}, io(self(), inputs), deps(dir))

      assert_received {:write, path}
      config = written_config(path)
      assert config["agent"]["max_concurrent_agents"] == 4
      assert config["max_vertical_panes"] == 2
      assert config["pre_warmed_sessions"] == 1
    end

    test "re-prompts on non-numeric or out-of-range input", %{dir: dir} do
      inputs = ["memory", "claude", "opus", "nope", "0", "5", "3", "3"]
      assert :ok = Init.run(%{force: false}, io(self(), inputs), deps(dir))

      assert_received {:puts, "Setting up aiur in this repo."}
      assert_received {:puts, message}
      assert message =~ "Enter a whole number"

      assert_received {:write, path}
      config = written_config(path)
      assert config["agent"]["max_concurrent_agents"] == 5
    end

    test "pre_warmed_sessions accepts 0 to disable warm-up", %{dir: dir} do
      inputs = ["memory", "claude", "opus", "10", "3", "0"]
      assert :ok = Init.run(%{force: false}, io(self(), inputs), deps(dir))

      assert_received {:write, path}
      assert written_config(path)["pre_warmed_sessions"] == 0
    end
  end

  describe "github label setup (U6, R8/R9)" do
    test "derives the full label set for the chosen backends and prefix", %{dir: dir} do
      inputs = ["github", "octo/repo", "team", "claude", "opus"]
      assert :ok = Init.run(%{force: false}, io(self(), inputs), deps(dir))

      assert_received {:labels, %{kind: "github"}, labels}
      assert "team:todo" in labels
      assert "team:human-review" in labels
      assert "model:claude" in labels
      assert "complexity:1" in labels
      assert "complexity:5" in labels
      refute Enum.any?(labels, &String.starts_with?(&1, "model:codex"))
    end

    test "prints a routing summary that names agents only, not skills or prompts", %{dir: dir} do
      inputs = ["github", "octo/repo", "team", "claude", "opus"]
      assert :ok = Init.run(%{force: false}, io(self(), inputs), deps(dir))

      assert_received {:puts, "  complexity:1 → claude"}

      assert_received {:puts, "A complexity label only selects the agent — it does not change skills or prompts."}
    end

    test "warns and proceeds when label creation fails (R6)", %{dir: dir} do
      overrides = %{create_labels: fn _tracker, _labels -> {:error, "needs repo write scope"} end}
      inputs = ["github", "octo/repo", "team", "claude", "opus"]

      assert :ok = Init.run(%{force: false}, io(self(), inputs), deps(dir, overrides))

      assert_received {:write, _}
      assert_received {:puts, "⚠ label setup skipped: needs repo write scope"}
    end

    test "skips the label step entirely for non-github trackers", %{dir: dir} do
      assert :ok = Init.run(%{force: false}, io(self(), ["memory"]), deps(dir))

      refute_received {:labels, _, _}
    end
  end

  describe "round-trip through the runtime config loader (U2 integration)" do
    test "emitted YAML parses into a valid Schema with defaults filled", %{dir: dir} do
      previous = Application.get_env(:aiur, :workflow_file_path)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:aiur, :workflow_file_path)
        else
          Application.put_env(:aiur, :workflow_file_path, previous)
        end
      end)

      inputs = ["github", "octo/repo", "team"]
      assert :ok = Init.run(%{force: false}, io(self(), inputs), deps(dir))
      assert_received {:write, path}

      Application.put_env(:aiur, :workflow_file_path, path)

      assert {:ok, settings} = Config.settings()
      assert settings.tracker.kind == "github"
      assert settings.agent.kind == "claude"
      assert settings.agent.routing == %{1 => "claude", 2 => "claude", 3 => "claude", 4 => "claude", 5 => "claude"}
      # Unprompted sections fall back to schema defaults.
      assert settings.polling.interval_seconds == 30
      assert settings.max_vertical_panes == 3
    end
  end
end
