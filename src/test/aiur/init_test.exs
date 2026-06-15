defmodule Aiur.InitTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.Labels
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
      input: fn label, default, _hint ->
        send(parent, {:input_label, label})
        Map.get(Map.get(answers, :input, %{}), label, default)
      end,
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
        load_config: fn t ->
          with {:ok, loaded} <- Workflow.load(t), do: {:ok, loaded.config}
        end,
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
        github_token: fn -> nil end,
        list_labels: fn _tracker -> {:ok, []} end,
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

  defp input_labels(acc \\ []) do
    receive do
      {:input_label, label} -> input_labels([label | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp auth_kinds(acc \\ []) do
    receive do
      {:auth_kind, kind} -> auth_kinds([kind | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp input_hints(acc \\ []) do
    receive do
      {:input_hint, label, hint} -> input_hints([{label, hint} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @duration_label "Max agent duration in minutes"

  @location_label "Where will you store aiur settings?"

  defp github_answers(overrides \\ %{}) do
    base = %{
      select: %{@location_label => "repo", "Issue tracker" => "github"},
      input: %{"GitHub repo (owner/name)" => "octo/repo"},
      multiselect: %{"Which agents to support" => ["claude"]}
    }

    Map.merge(base, overrides, fn _k, v1, v2 -> Map.merge(v1, v2) end)
  end

  describe "existing-config handling" do
    test "an unreadable existing config errors with a --force hint", %{dir: dir, target: target} do
      File.write!(target, "- not\n- a\n- map\n")

      assert {:error, message} =
               Init.run(%{force: false}, io(self()), deps(self(), dir, target))

      assert message =~ "Couldn't read"
      assert message =~ "--force"
    end

    test "proceeds when the target exists but --force is passed", %{dir: dir, target: target} do
      File.write!(target, "existing")

      assert :ok =
               Init.run(%{force: true}, io(self(), github_answers()), deps(self(), dir, target))
    end

    test "a valid existing config resumes: skips intro, shows summary, provisions", %{
      dir: dir,
      target: target
    } do
      d = deps(self(), dir, target)
      # First run writes a valid config.
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), d)
      _ = puts_log()
      _ = input_labels()

      # Re-run with no scripted intro answers: it must resume, not re-ask.
      assert :ok = Init.run(%{force: false}, io(self()), d)

      refute Enum.any?(input_labels(), &(&1 =~ ~r/Where should agents work/))
      assert Enum.any?(puts_log(), &(&1 =~ ~r/Saved selections/i))
    end

    test "resume never runs a CLI auth check for the claude-repl transport", %{
      dir: dir,
      target: target
    } do
      parent = self()
      # existing_config_path only needs the file to exist; load_config is stubbed.
      File.write!(target, "placeholder")

      config = %{
        "tracker" => %{"kind" => "memory"},
        "agent" => %{"kind" => "claude", "routing" => %{"5" => "claude-repl"}}
      }

      d =
        deps(parent, dir, target, %{
          load_config: fn _t -> {:ok, config} end,
          check_agent_auth: fn kind ->
            send(parent, {:auth_kind, kind})
            :ok
          end
        })

      assert :ok = Init.run(%{force: false}, io(parent), d)

      kinds = auth_kinds()
      assert "claude" in kinds
      refute "claude-repl" in kinds
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

  describe "limits and helper text" do
    test "max turns defaults to none (uncapped)", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))
      assert written_config(target)["agent"]["max_turns"] == "none"
    end

    test "the polling question explains what polling does", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))
      assert Enum.any?(input_labels(), &(&1 =~ ~r/check the tracker for new work/i))
    end

    test "limit and pre-warm prompts carry their helper text as hints", %{dir: dir, target: target} do
      parent = self()
      answers = github_answers()
      base = io(parent, answers)

      capturing = %{
        base
        | input: fn label, default, hint ->
            send(parent, {:input_hint, label, hint})
            Map.get(Map.get(answers, :input, %{}), label, default)
          end
      }

      assert :ok = Init.run(%{force: false}, capturing, deps(parent, dir, target))

      hints = input_hints()

      assert {"Max turns per issue", "none = unlimited"} in hints

      assert {"How many opencode sessions would you like to pre-warm?",
              "Set this to how many opencode panes you expect to open at once."} in hints

      assert Enum.any?(hints, fn {label, hint} ->
               label == "Max agent duration in minutes" and hint =~ "Fallback for stuck agents"
             end)
    end

    test "a numeric max agent duration is written", %{dir: dir, target: target} do
      answers = github_answers(%{input: %{@duration_label => "30"}})

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))
      assert written_config(target)["agent"]["max_agent_duration_minutes"] == 30
    end

    test "max agent duration of none disables the watchdog (writes 0)", %{dir: dir, target: target} do
      answers = github_answers(%{input: %{@duration_label => "none"}})

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))
      assert written_config(target)["agent"]["max_agent_duration_minutes"] == 0
    end
  end

  describe "agents, routing, permission mode" do
    test "the agent multiselect offers only claude and codex (never claude-repl)", %{
      dir: dir,
      target: target
    } do
      parent = self()
      answers = github_answers()
      base = io(parent, answers)

      capturing = %{
        base
        | multiselect: fn label, opts, defaults ->
            send(parent, {:multiselect_opts, label, opts})
            Map.get(Map.get(answers, :multiselect, %{}), label, defaults)
          end
      }

      assert :ok = Init.run(%{force: false}, capturing, deps(parent, dir, target))

      assert_received {:multiselect_opts, "Which agents to support", opts}
      assert opts == ["claude", "codex"]
    end

    test "the routing walkthrough sets a model and optional remote per tag", %{dir: dir, target: target} do
      answers =
        github_answers(%{
          multiselect: %{"Which agents to support" => ["claude", "codex"]},
          select: %{
            "complexity:1" => "claude:haiku",
            "complexity:2" => "codex",
            "complexity:3" => "claude",
            "complexity:4" => "claude",
            "complexity:5" => "claude:sonnet"
          },
          confirm: %{"Run complexity:1 in remote-control mode?" => true}
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))

      routing = written_config(target)["agent"]["routing"]
      # complexity:1 -> default haiku, run in remote mode.
      assert routing[1] == "claude:haiku+remote"
      assert routing[2] == "codex"
      assert routing[5] == "claude:sonnet"

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/optimize effort per ticket/i))
      assert Enum.any?(log, &(&1 =~ ~r/override these by tagging/i))
    end

    test "codex routing tags are never offered remote mode", %{dir: dir, target: target} do
      parent = self()

      answers =
        github_answers(%{
          multiselect: %{"Which agents to support" => ["codex"]},
          # If a codex level were offered remote and we said yes, it would
          # append +remote; scripting yes proves the prompt is never asked.
          confirm: %{"Run complexity:3 in remote-control mode?" => true}
        })

      assert :ok = Init.run(%{force: false}, io(parent, answers), deps(parent, dir, target))

      routing = written_config(target)["agent"]["routing"]
      refute Enum.any?(routing, fn {_level, value} -> String.contains?(value, "+remote") end)
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

    test "with no token: explains the next step and skips label creation", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/run `aiur init` again/i))
      refute_received {:labels, _tracker, _labels}
    end

    test "with a token: creates labels and shows the ready screen", %{dir: dir, target: target} do
      deps = deps(self(), dir, target, %{github_token: fn -> "ghp_test" end})

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps)

      assert_received {:labels, %{kind: "github"}, labels} when is_list(labels)
      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/agent:todo/))
      assert Enum.any?(log, &(&1 =~ ~r/aiur --bg/))
    end

    test "lists every label with a description, including model:claude-remote", %{dir: dir, target: target} do
      deps = deps(self(), dir, target, %{github_token: fn -> "ghp_test" end})

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps)

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/model:claude-remote — Forces remote-control mode at launch/))
      assert Enum.any?(log, &(&1 =~ ~r/agent:todo — ready to be worked/))
    end

    test "permission failure prints a gh fallback and withholds the ready screen", %{
      dir: dir,
      target: target
    } do
      deps =
        deps(self(), dir, target, %{
          github_token: fn -> "ghp_test" end,
          create_labels: fn _tracker, _labels -> {:error, "the token needs repo write scope"} end
        })

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps)

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/gh label create/))
      assert Enum.any?(log, &(&1 =~ ~r/run `aiur init` again/i))
      refute Enum.any?(log, &(&1 =~ ~r/aiur is set up/i))
    end

    test "all labels already present: no creation, shows the ready screen", %{dir: dir, target: target} do
      required = Labels.label_set("agent", ["claude"])

      deps =
        deps(self(), dir, target, %{
          github_token: fn -> "ghp_test" end,
          list_labels: fn _tracker -> {:ok, required} end
        })

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps)

      refute_received {:labels, _tracker, _labels}
      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/already exist/i))
      assert Enum.any?(log, &(&1 =~ ~r/aiur is set up/i))
    end

    test "creates only the missing labels on a later run", %{dir: dir, target: target} do
      required = Labels.label_set("agent", ["claude"])
      present = required -- ["agent:rework", "complexity:5"]

      deps =
        deps(self(), dir, target, %{
          github_token: fn -> "ghp_test" end,
          list_labels: fn _tracker -> {:ok, present} end
        })

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps)

      assert_received {:labels, _tracker, missing}
      assert Enum.sort(missing) == Enum.sort(["agent:rework", "complexity:5"])
    end

    test "the missing-label gh fallback lists only the missing labels", %{dir: dir, target: target} do
      required = Labels.label_set("agent", ["claude"])
      present = required -- ["complexity:5"]

      deps =
        deps(self(), dir, target, %{
          github_token: fn -> "ghp_test" end,
          list_labels: fn _tracker -> {:ok, present} end,
          create_labels: fn _tracker, _labels -> {:error, "no permission"} end
        })

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps)

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/gh label create 'complexity:5'/))
      refute Enum.any?(log, &(&1 =~ ~r/gh label create 'agent:todo'/))
    end
  end
end
