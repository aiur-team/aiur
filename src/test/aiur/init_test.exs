defmodule Aiur.InitTest do
  use ExUnit.Case, async: true

  alias Aiur.Init
  alias Aiur.Workflow

  @example_file Path.expand("../../../.aiurconfig.example", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-init-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    target = Path.join(dir, ".aiurconfig")
    # The wizard writes `prompt_file: AIUR.md`; Workflow.load resolves it, so
    # the file must exist alongside the config for the written config to load.
    File.write!(Path.join(dir, "AIUR.md"), "# agent prompt\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, target: target}
  end

  # Label-keyed scripted io: each prompt looks up its answer by label and
  # falls back to the supplied default, so a test scripts only the answers it
  # cares about regardless of prompt order.
  defp io(parent, answers \\ %{}) do
    %{
      puts: fn message ->
        send(parent, {:puts, IO.chardata_to_string(message)})
        :ok
      end,
      input: fn label, default -> Map.get(Map.get(answers, :input, %{}), label, default) end,
      select: fn label, _opts, default -> Map.get(Map.get(answers, :select, %{}), label, default) end,
      multiselect: fn label, _opts, defaults ->
        Map.get(Map.get(answers, :multiselect, %{}), label, defaults)
      end,
      confirm: fn label, default -> Map.get(Map.get(answers, :confirm, %{}), label, default) end
    }
  end

  defp deps(parent, dir, target, overrides \\ %{}) do
    Map.merge(
      %{
        config_target: fn _location -> target end,
        existing_config_path: fn t -> if File.regular?(t), do: t end,
        read_example: fn -> File.read!(@example_file) end,
        detect_repo: fn -> nil end,
        write_config: fn t, yaml ->
          File.write!(t, yaml)
          send(parent, {:write, t})
          {:ok, t}
        end,
        ensure_prompt_file: fn t, pf ->
          path = Path.expand(pf, Path.dirname(t))

          if File.regular?(path) do
            {:exists, path}
          else
            File.write!(path, "# prompt\n")
            {:created, path}
          end
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

  defp puts_log(acc \\ []) do
    receive do
      {:puts, msg} -> puts_log([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @location_label "Where will you store aiur settings?"

  defp github_answers(overrides \\ %{}) do
    base = %{
      select: %{@location_label => "repo", "Issue tracker" => "github"},
      input: %{"GitHub repo (owner/name)" => "octo/repo"},
      multiselect: %{"Which agents to support" => ["claude"]},
      confirm: %{"Set specific models per complexity tag?" => false}
    }

    Map.merge(base, overrides, fn _k, v1, v2 -> Map.merge(v1, v2) end)
  end

  describe "existing-config guard" do
    test "aborts when the target config exists and --force is not passed", %{dir: dir, target: target} do
      File.write!(target, "existing")

      assert {:error, message} =
               Init.run(%{force: false}, io(self()), deps(self(), dir, target))

      assert message =~ "already exists"
      assert message =~ "--force"
    end

    test "proceeds when the target exists but --force is passed", %{dir: dir, target: target} do
      File.write!(target, "existing")

      assert :ok =
               Init.run(%{force: true}, io(self(), github_answers()), deps(self(), dir, target))
    end
  end

  describe "tracker prompts fill the nested template" do
    test "github writes tracker.github.* and a routing table", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))

      config = written_config(target)
      assert config["tracker"]["kind"] == "github"
      assert config["tracker"]["github"]["repo"] == "octo/repo"
      # label_prefix is fixed (`agent`) and omitted from the written config.
      refute Map.has_key?(config["tracker"]["github"], "label_prefix")
      assert config["agent"]["kind"] == "claude"
      assert config["agent"]["max_agent_duration_minutes"] == 60

      routing = config["agent"]["routing"]
      assert map_size(routing) == 5
      assert routing |> Map.values() |> Enum.uniq() == ["claude"]
    end

    test "the global config omits the repo (auto-detected at runtime)", %{dir: dir, target: target} do
      answers = github_answers(%{select: %{@location_label => "global"}})

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))

      config = written_config(target)
      assert config["tracker"]["kind"] == "github"
      refute Map.has_key?(config["tracker"]["github"] || %{}, "repo")
    end

    test "linear writes tracker.linear.* and warns that support is limited", %{dir: dir, target: target} do
      answers = %{
        select: %{@location_label => "repo", "Issue tracker" => "linear"},
        input: %{"Linear API key" => "lin_key_123", "Linear project slug" => "team-alpha"},
        multiselect: %{"Which agents to support" => ["codex"]},
        confirm: %{"Set specific models per complexity tag?" => false}
      }

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))

      config = written_config(target)
      assert config["tracker"]["kind"] == "linear"
      assert config["tracker"]["linear"]["api_key"] == "lin_key_123"
      assert config["tracker"]["linear"]["project_slug"] == "team-alpha"

      assert Enum.any?(puts_log(), &(&1 =~ ~r/Linear support is LIMITED/i))
    end

    test "repo-local init creates the prompt file the config references", %{dir: dir, target: target} do
      File.rm!(Path.join(dir, "AIUR.md"))

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))
      assert File.regular?(Path.join(dir, "AIUR.md"))
    end

    test "the global config omits the repo-specific prompt_file", %{dir: dir, target: target} do
      answers = github_answers(%{select: %{@location_label => "global"}})

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))
      assert written_config(target)["prompt_file"] == nil
    end

    test "memory writes a minimal tracker", %{dir: dir, target: target} do
      answers = %{
        select: %{@location_label => "repo", "Issue tracker" => "memory"},
        multiselect: %{"Which agents to support" => ["codex"]},
        confirm: %{"Set specific models per complexity tag?" => false}
      }

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))
      assert written_config(target)["tracker"]["kind"] == "memory"
    end
  end

  describe "agents, routing, permission mode" do
    test "agent selection does not hint remote-control (deferred to tag creation)", %{
      dir: dir,
      target: target
    } do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))
      refute Enum.any?(puts_log(), &(&1 =~ ~r/remote-control mode/i))
    end

    test "the routing walkthrough sets backend:model per complexity tag", %{dir: dir, target: target} do
      answers =
        github_answers(%{
          multiselect: %{"Which agents to support" => ["claude", "codex"]},
          confirm: %{"Set specific models per complexity tag?" => true},
          select: %{
            "complexity:1" => "codex",
            "complexity:2" => "codex",
            "complexity:3" => "claude",
            "complexity:4" => "claude",
            "complexity:5" => "claude:sonnet"
          }
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))

      routing = written_config(target)["agent"]["routing"]
      assert routing[1] == "codex"
      assert routing[5] == "claude:sonnet"

      assert Enum.any?(puts_log(), &(&1 =~ ~r/default Claude version/i))
    end

    test "interactive permission modes redirect to bypassPermissions", %{dir: dir, target: target} do
      answers = github_answers(%{select: %{"Claude permission mode" => "acceptEdits (coming soon)"}})

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))

      assert written_config(target)["agent"]["claude"]["permission_mode"] == "bypassPermissions"
      assert Enum.any?(puts_log(), &(&1 =~ ~r/coming soon/i))
    end
  end

  describe "closing steps (github)" do
    test "scaffolds .env and walks through the bot-account token", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))

      assert File.read!(Path.join(dir, ".env.example")) =~ "GITHUB_TOKEN="
      assert File.read!(Path.join(dir, ".env")) =~ "GITHUB_TOKEN="

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/bot account/i))
      assert Enum.any?(log, &(&1 =~ "settings/tokens"))
    end

    test "creates the labels aiur routes on", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))
      assert_received {:labels, %{kind: "github"}, labels} when is_list(labels)
    end
  end
end
