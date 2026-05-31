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
