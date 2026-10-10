defmodule Aiur.Init.AgentsAndClosingTest do
  use Aiur.InitCase

  @bot_account_label "GitHub account Aiur's agents post as"

  @github_app_label "Use a GitHub App for the daemon? (recommended if agents are hitting rate limits)"
  @github_token_choice "No — use my GITHUB_TOKEN"
  @github_app_choice "Yes — I'll set up a GitHub App"

  describe "agents, routing, permission mode" do
    test "the agent multiselect offers only configurable backends (never claude-repl or deepseek)", %{
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
      assert opts == CodingAgent.configurable_backends()
      refute "claude-repl" in opts
      # DeepSeek is registered but not dispatch-enabled by default, so it must
      # not be offerable from init.
      refute "deepseek" in opts
    end

    test "the location options carry greyed config-path help", %{dir: dir, target: target} do
      parent = self()
      answers = github_answers()
      base = io(parent, answers)

      capturing = %{
        base
        | select: fn label, opts, default ->
            send(parent, {:select_opts, label, opts})
            Map.get(Map.get(answers, :select, %{}), label, default)
          end
      }

      assert :ok = Init.run(%{force: false}, capturing, deps(parent, dir, target))

      assert_received {:select_opts, "Where will you store aiur settings for this project?", opts}
      assert opts == ["repo (./.aiur/)", "global (~/.aiur/)"]
    end

    test "accepting the gate sets a default model per complexity tag", %{dir: dir, target: target} do
      answers =
        github_answers(%{
          multiselect: %{"Which agents to support" => ["claude", "codex"]},
          confirm: %{"Would you like to select models and effort for 5 complexity tags?" => true},
          select: %{
            "complexity:1 backend" => "claude",
            "complexity:1 claude model" => "haiku",
            "complexity:2 backend" => "codex",
            "complexity:2 codex model" => "gpt-5.6-luna",
            "complexity:2 codex effort" => "high",
            "complexity:5 backend" => "claude",
            "complexity:5 claude model" => "sonnet"
          }
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))

      routing = written_config(target)["agent"]["routing"]
      assert routing[1] == "claude:haiku"
      assert routing[2] == "codex:gpt-5.6-luna:high"
      assert routing[5] == "claude:sonnet"
      # unscripted tags fall to the primary default; no remote prompt is asked.
      assert routing[3] == "claude"
      refute Enum.any?(routing, fn {_level, value} -> String.contains?(value, "+remote") end)

      assert Enum.any?(puts_log(), &(&1 =~ ~r/optimize agent effort per ticket/i))
    end

    test "declining the gate routes every tag to the primary default", %{dir: dir, target: target} do
      answers =
        github_answers(%{
          confirm: %{"Would you like to select models and effort for 5 complexity tags?" => false}
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))

      routing = written_config(target)["agent"]["routing"]
      assert routing |> Map.values() |> Enum.uniq() == ["claude"]
    end

    test "routing effort choices are scoped to the selected backend", %{dir: dir, target: target} do
      parent = self()

      answers =
        github_answers(%{
          multiselect: %{"Which agents to support" => ["claude", "codex"]},
          confirm: %{"Would you like to select models and effort for 5 complexity tags?" => true},
          select: %{
            "complexity:1 backend" => "claude",
            "complexity:2 backend" => "codex"
          }
        })

      base = io(parent, answers)

      capturing = %{
        base
        | select: fn label, opts, default ->
            send(parent, {:select_opts, label, opts})
            Map.get(Map.get(answers, :select, %{}), label, default)
          end
      }

      assert :ok = Init.run(%{force: false}, capturing, deps(parent, dir, target))

      refute_received {:select_opts, "complexity:1 claude effort", _claude_efforts}

      assert_received {:select_opts, "complexity:2 codex effort", codex_efforts}
      assert codex_efforts == ["default effort", "none", "low", "medium", "high", "xhigh", "max"]
    end

    test "interactive permission modes redirect to bypassPermissions", %{dir: dir, target: target} do
      answers = github_answers(%{select: %{"Claude permission mode" => "acceptEdits (coming soon)"}})

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))

      assert written_config(target)["agent"]["claude"]["permission_mode"] == "bypassPermissions"
      assert Enum.any?(puts_log(), &(&1 =~ ~r/coming soon/i))
    end
  end

  describe "closing steps (github)" do
    test "offers GitHub App auth once and defaults to GITHUB_TOKEN", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))
      assert :ok = Init.run(%{force: false}, io(self()), deps(self(), dir, target))

      app_prompts =
        select_prompts()
        |> Enum.filter(fn {label, _options, _default} -> label == @github_app_label end)

      assert app_prompts == [
               {@github_app_label, [@github_token_choice, @github_app_choice], @github_token_choice}
             ]

      log = Enum.join(puts_log(), "\n")
      assert log =~ "Higher rate limits for busy fleets."
      assert log =~ "Tighter daemon permissions than a classic PAT."
      refute log =~ "docs/security/daemon-token-posture.md"

      events_after_choice =
        io_trace()
        |> Enum.drop_while(&(&1 != {:select, @github_app_label}))
        |> Enum.drop(1)

      refute Enum.any?(events_after_choice, fn
               {:puts, message} -> String.contains?(message, "GitHub App")
               _event -> false
             end)
    end

    test "GitHub App choice points to setup steps without inlining the PAT walkthrough", %{
      dir: dir,
      target: target
    } do
      answers = github_answers(%{select: %{@github_app_label => @github_app_choice}})
      parent = self()
      base_io = io(parent, answers)

      capturing_io = %{
        base_io
        | input: fn label, default, hint ->
            send(parent, {:input_hint, label, hint})
            Map.get(Map.get(answers, :input, %{}), label, default)
          end
      }

      deps =
        deps(parent, dir, target, %{
          detect_default_branch: fn _repo -> "release" end,
          github_token: fn -> "ghp_existing" end,
          check_ci_readiness: fn _tracker -> flunk("App choice must not provision through a PAT") end,
          list_labels: fn _tracker -> flunk("App choice must not list labels through a PAT") end,
          create_labels: fn _tracker, _labels -> flunk("App choice must not create labels through a PAT") end
        })

      assert :ok = Init.run(%{force: false}, capturing_io, deps)

      log = Enum.join(puts_log(), "\n")
      hints = input_hints()

      refute Enum.any?(hints, fn {label, _hint} -> label == @bot_account_label end)

      refute Enum.any?(hints, fn {_label, hint} ->
               is_binary(hint) and String.contains?(hint, "App bot login")
             end)

      assert log =~
               "GitHub App setup steps: https://github.com/aiur-team/aiur/blob/release/docs/security/daemon-token-posture.md"

      refute log =~ "Generate new token (classic)"
      refute log =~ "GITHUB_APP_ID"
      refute log =~ "Generate and download a private key"
      refute File.exists?(Path.join(dir, ".env"))
      refute_received {:labels, _tracker, _labels}
    end

    test "scaffolds only .env and walks through the bot-account token", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))

      assert File.read!(Path.join(dir, ".env")) == "GITHUB_TOKEN=\n"
      refute File.exists?(Path.join(dir, ".env.example"))

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/bot account/i))
      assert Enum.any?(log, &(&1 =~ "settings/tokens"))
      assert Enum.any?(log, &(&1 =~ "Fine-grained token (recommended)"))
      assert Enum.any?(log, &(&1 =~ "broad access that includes Administration"))
    end

    test "closing file lines use Created:/Found: and drop the setup preamble", %{
      dir: dir,
      target: target
    } do
      # Pre-create .env so it is reported as Found, not Created.
      File.write!(Path.join(dir, ".env"), "GITHUB_TOKEN=\n")

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/^Created: /))
      assert Enum.any?(log, &(&1 =~ ~r/^Found: /))
      refute Enum.any?(log, &(&1 =~ ~r/leaving it in place/))
      refute Enum.any?(log, &(&1 =~ ~r/^Wrote /))
      refute Enum.any?(log, &(&1 =~ ~r/Setting up aiur/))
    end

    test "with no token: explains the next step and skips label creation", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/run `aiur init` again/i))
      refute_received {:labels, _tracker, _labels}
    end

    test "no-token instructions recommend fine-grained and label classic as broad", %{
      dir: dir,
      target: target
    } do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))

      log = puts_log()
      joined = Enum.join(log, "\n")

      assert joined =~ "Generate new token (classic)"
      assert joined =~ "Administration: Read-only"
      assert joined =~ "Fine-grained token (recommended)"
      assert joined =~ "Check `repo` (broad access that includes Administration)"
      assert joined =~ "Only select repositories"
      assert joined =~ "Read and write"
      assert joined =~ "Issues"
      assert joined =~ "Contents: Read and write"
      assert joined =~ "Pull requests"
      assert joined =~ "write access to this repo"
    end

    test "with a token: creates labels and shows the ready screen", %{dir: dir, target: target} do
      deps = deps(self(), dir, target, %{github_token: fn -> "ghp_test" end})

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps)

      assert_received {:labels, %{kind: "github"}, labels} when is_list(labels)
      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/agent:todo/))
      assert Enum.any?(log, &(&1 =~ ~r/aiur --bg/))
    end

    test "each label stage prints its header and greyed helper", %{dir: dir, target: target} do
      deps = deps(self(), dir, target, %{github_token: fn -> "ghp_test" end})

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps)

      log = puts_log()
      # stage 2 — complexity
      assert Enum.any?(log, &(&1 =~ ~r/story point complexity labels/))
      assert Enum.any?(log, &(&1 =~ ~r/Used to optimize effort/))
      # stage 3 — model overrides
      assert Enum.any?(log, &(&1 =~ ~r/route specific issues to different models/))
      assert Enum.any?(log, &(&1 =~ ~r/override complexity label model choices/))
      # stage 4 — remote (claude is selected)
      assert Enum.any?(log, &(&1 =~ ~r/open a ticket in remote-control mode/))
      assert Enum.any?(log, &(&1 =~ ~r/Supports claude remote-control/))
    end

    test "lists every label with a description, including model:remote", %{dir: dir, target: target} do
      deps = deps(self(), dir, target, %{github_token: fn -> "ghp_test" end})

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps)

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/model:remote\s+— Supports claude remote-control/))
      assert Enum.any?(log, &(&1 =~ ~r/agent:todo\s+— ready to be worked/))
    end

    test "shorter labels are padded so the description column aligns", %{dir: dir, target: target} do
      deps = deps(self(), dir, target, %{github_token: fn -> "ghp_test" end})

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps)

      # agent:todo (short) is padded toward agent:human-review (longest) before the —.
      assert Enum.any?(puts_log(), &(&1 =~ ~r/agent:todo\s{2,}—/))
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

    test "all labels already present: status lines, no prompts, ready screen", %{
      dir: dir,
      target: target
    } do
      required = Labels.label_set("agent", ["claude"])

      deps =
        deps(self(), dir, target, %{
          github_token: fn -> "ghp_test" end,
          list_labels: fn _tracker -> {:ok, required} end
        })

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps)

      # Nothing created, and no label stage prompted — every group was present.
      refute_received {:labels, _tracker, _labels}
      prompts = confirm_prompts()
      refute "Create the complexity labels?" in prompts
      refute "Create the model labels?" in prompts
      refute "Create the model:remote label?" in prompts
      refute Enum.any?(input_labels(), &(&1 =~ ~r/Press Enter to create/i))

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/Required agent tags: created\./))
      assert Enum.any?(log, &(&1 =~ ~r/Complexity tags: created\./))
      assert Enum.any?(log, &(&1 =~ ~r/Model tags: created\./))
      assert Enum.any?(log, &(&1 =~ ~r/aiur is set up/i))
    end

    test "later run reprompts only the stages with missing labels", %{dir: dir, target: target} do
      required = Labels.label_set("agent", ["claude"])
      present = required -- ["agent:rework", "complexity:5"]

      deps =
        deps(self(), dir, target, %{
          github_token: fn -> "ghp_test" end,
          list_labels: fn _tracker -> {:ok, present} end
        })

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps)

      assert Enum.sort(labels_created()) == Enum.sort(["agent:rework", "complexity:5"])

      # Required labels (agent:rework missing) re-prompt the Enter gate; complexity
      # (complexity:5 missing) re-asks its confirm. Fully-present stages do not.
      assert Enum.any?(input_labels(), &(&1 =~ ~r/Press Enter to create/i))
      prompts = confirm_prompts()
      assert "Create the complexity labels?" in prompts
      refute "Create the model labels?" in prompts
      refute "Create the model:remote label?" in prompts

      assert Enum.any?(puts_log(), &(&1 =~ ~r/Model tags: created\./))
    end

    test "required labels are gated behind an explicit Enter", %{dir: dir, target: target} do
      deps = deps(self(), dir, target, %{github_token: fn -> "ghp_test" end})

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps)

      assert Enum.any?(input_labels(), &(&1 =~ ~r/Press Enter to create/i))
      assert Enum.any?(puts_log(), &(&1 =~ ~r/workflow and automatic-fallback labels are required/i))
    end

    test "optional stages can be skipped without creating their labels", %{dir: dir, target: target} do
      deps = deps(self(), dir, target, %{github_token: fn -> "ghp_test" end})

      answers =
        github_answers(%{
          confirm: %{
            "Create the complexity labels?" => false,
            "Create the model labels?" => false,
            "Create the effort labels?" => false,
            "Create the model:remote label?" => false
          }
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps)

      created = labels_created()
      assert created != []
      required = Labels.state_labels("agent") ++ Labels.required_rate_limit_fallback_labels("agent")
      assert Enum.sort(created) == Enum.sort(required)
      refute Enum.any?(created, &String.starts_with?(&1, "complexity:"))
      assert "model:claude" in created
      refute "model:codex" in created
      refute "model:claude-repl" in created
    end

    test "the remote-control stage only appears when claude is supported", %{dir: dir, target: target} do
      deps = deps(self(), dir, target, %{github_token: fn -> "ghp_test" end})
      answers = github_answers(%{multiselect: %{"Which agents to support" => ["codex"]}})

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps)

      log = puts_log()
      refute Enum.any?(log, &(&1 =~ ~r/remote-control mode/i))
      refute Enum.any?(log, &(&1 =~ ~r/model:remote/))
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
