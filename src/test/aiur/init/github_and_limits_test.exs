defmodule Aiur.Init.GithubAndLimitsTest do
  use Aiur.InitCase

  @duration_label "Max agent duration in minutes"
  @location_label "Where will you store aiur settings for this project?"

  describe "tracker prompts fill the nested template" do
    test "the issue tracker offers github and linear, never memory", %{dir: dir, target: target} do
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

      assert_received {:select_opts, "Issue tracker", opts}
      assert opts == ["github", "linear"]
    end

    test "github writes tracker.github.* and a routing table", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))

      assert_received {:repo_state, %{kind: "github", repo: "octo/repo"}}

      config = written_config(target)
      assert config["tracker"]["kind"] == "github"
      assert config["tracker"]["github"]["repo"] == "octo/repo"
      # label_prefix is fixed (`agent`) and omitted from the written config.
      refute Map.has_key?(config["tracker"]["github"], "label_prefix")
      assert config["agent"]["priority"] == ["claude"]
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

    test "global init checks the current repository without storing it", %{dir: dir, target: target} do
      answers = github_answers(%{select: %{@location_label => "global"}, confirm: %{"No pull-request CI workflow found — scaffold .github/workflows/ci.yml?" => false}})

      deps =
        deps(self(), dir, target, %{
          github_token: fn -> "ghp_test" end,
          detect_repo: fn -> "octo/current-repo" end,
          check_ci_readiness: fn tracker ->
            send(self(), {:readiness_tracker, tracker})
            {:ok, %{ready?: false, base_branch: "main", workflow_paths: [], issues: [:no_pr_workflow]}}
          end
        })

      assert {:error, _} = Init.run(%{force: false}, io(self(), answers), deps)
      assert_received {:readiness_tracker, %{repo: "octo/current-repo", base_branch: "main"}}
      refute Map.has_key?(written_config(target)["tracker"]["github"] || %{}, "repo")
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
      File.rm!(Path.join([dir, ".aiur", "prompt.md"]))

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))
      assert File.regular?(Path.join([dir, ".aiur", "prompt.md"]))
    end

    test "repo-local init creates the .aiur/hooks the config references", %{dir: dir, target: target} do
      File.rm_rf!(Path.join([dir, ".aiur", "hooks"]))

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))
      assert File.regular?(Path.join([dir, ".aiur", "hooks"]))
    end

    test "repo-local init does not copy example templates into the repo", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))
      refute File.dir?(Path.join([dir, ".aiur", "examples"]))
    end

    test "repo-local init appends .aiur/ to .gitignore when accepted", %{dir: dir, target: target} do
      answers = github_answers(%{confirm: %{"Add .aiur/ to .gitignore?" => true}})

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))
      assert File.read!(Path.join(dir, ".gitignore")) =~ ".aiur/"
    end

    test "repo-local init leaves .gitignore untouched when declined", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))
      refute File.regular?(Path.join(dir, ".gitignore"))
    end

    test "global init does not offer the gitignore prompt", %{dir: dir, target: target} do
      answers = github_answers(%{select: %{@location_label => "global"}})

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))
      refute_received {:gitignore, _entry}
    end

    test "init does not clobber an existing .aiur/hooks", %{dir: dir, target: target} do
      hooks_path = Path.join([dir, ".aiur", "hooks"])
      File.write!(hooks_path, "after_create: my custom hook\n")

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))
      assert File.read!(hooks_path) == "after_create: my custom hook\n"
    end

    test "the scaffolded prompt file delivers the issue task to the agent" do
      template = Init.prompt_file_template()

      # PromptBuilder renders prompt_file as the whole turn template, so it
      # must reference the issue or the agent receives no task.
      assert template =~ "{{ issue.identifier }}"
      assert template =~ "{{ issue.title }}"
      assert template =~ "issue.description"
    end

    test "the prompt scaffold fills the repo name and preserves issue Liquid" do
      scaffold = Init.prompt_file_scaffold("octo/repo")

      assert scaffold =~ "octo/repo"
      # The {{REPO}} placeholder is init-filled; turn-time issue Liquid must
      # survive untouched so PromptBuilder can still render it.
      assert scaffold =~ "{{ issue.title }}"
      refute scaffold =~ "{{REPO}}"
    end

    test "the prompt scaffold falls back when no repo is known" do
      scaffold = Init.prompt_file_scaffold(nil)

      # No stray placeholder ever reaches Solid (strict_variables would raise).
      refute scaffold =~ "{{REPO}}"
      assert scaffold =~ "{{ issue.title }}"
    end

    test "the .aiurhooks scaffold defines workspace hooks against the repo URL" do
      template = Init.aiurhooks_template()

      # init writes this next to a config that references it via `hooks_file:`,
      # so it must carry the workspace bootstrap hooks (clone + branch).
      assert template =~ "after_create:"
      assert template =~ "before_run:"
      assert template =~ "$THIS_REPOSITORY_URL"
      assert template =~ "$AIUR_REPO_STATE_PATH"
      assert template =~ "move_sidecars_to_state"
    end

    test "the global config omits the repo-specific prompt_file", %{dir: dir, target: target} do
      answers = github_answers(%{select: %{@location_label => "global"}})

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))
      assert written_config(target)["prompt_file"] == nil
    end
  end

  describe "github bot_account setup (#1152)" do
    @bot_account_label "GitHub account Aiur's agents post as"
    @identity_mode_label "Will Aiur's agents post as your own GitHub account, or as a separate bot account?"

    test "persists the token's detected login accepted as the default", %{dir: dir, target: target} do
      d = deps(self(), dir, target, %{github_bot_account_default: fn -> "its-applekid" end})

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), d)

      assert written_config(target)["tracker"]["github"]["bot_account"] == "its-applekid"
    end

    test "persists a normalized custom login over the default", %{dir: dir, target: target} do
      answers =
        github_answers(%{
          select: %{@identity_mode_label => "A separate bot account"},
          input: %{@bot_account_label => "@Custom-Bot"}
        })

      d = deps(self(), dir, target, %{github_bot_account_default: fn -> "octocat" end})

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      assert written_config(target)["tracker"]["github"]["bot_account"] == "custom-bot"
    end

    test "separate-account setup trusts the operator without a second CODEOWNERS confirmation", %{dir: dir, target: target} do
      answers =
        github_answers(%{
          select: %{@identity_mode_label => "A separate bot account"},
          input: %{@bot_account_label => "agent-bot"}
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))

      assert File.read!(codeowners_path(dir)) =~ "@octocat"
      refute File.read!(codeowners_path(dir)) =~ "@agent-bot"
      prompts = confirm_prompts()
      assert "Create .github/CODEOWNERS for aiur's GitHub trust checks?" in prompts
      refute Enum.any?(prompts, &String.contains?(&1, "Add @"))
    end

    test "asks one plain-language identity-mode question during setup", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))

      log = Enum.join(puts_log(), "\n")
      assert Enum.count(io_trace(), &(&1 == {:select, @identity_mode_label})) == 1
      assert log =~ "mark its comments"
      refute log =~ "#2356"
      refute log =~ "identity_mode"
    end

    test "a blank answer skips bot_account and writes no key", %{dir: dir, target: target} do
      answers = github_answers(%{select: %{@identity_mode_label => "A separate bot account"}, input: %{@bot_account_label => ""}})
      d = deps(self(), dir, target, %{github_bot_account_default: fn -> nil end})

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      refute Map.has_key?(written_config(target)["tracker"]["github"], "bot_account")
      assert written_config(target)["tracker"]["github"]["identity_mode"] == "separate_account"
    end

    test "a blank human account retains a detected bot without asking for a CODEOWNERS account", %{dir: dir, target: target} do
      answers = github_answers(%{input: %{"Your GitHub account" => ""}})

      d =
        deps(self(), dir, target, %{
          github_login: fn -> nil end,
          github_bot_account_default: fn -> "agent-bot" end
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      github = written_config(target)["tracker"]["github"]
      assert github["bot_account"] == "agent-bot"
      assert github["identity_mode"] == "separate_account"
      # Future guard: template enumeration has always omitted wizard-only keys.
      refute Map.has_key?(github, "operator_account_skipped")
      refute "GitHub account to add to CODEOWNERS" in input_labels()
      refute File.read!(codeowners_path(dir)) =~ "@agent-bot"
    end

    test "a blank human account with no bot does not prompt for CODEOWNERS again", %{dir: dir, target: target} do
      answers = github_answers(%{input: %{"Your GitHub account" => ""}})
      d = deps(self(), dir, target, %{github_login: fn -> nil end, github_bot_account_default: fn -> nil end})

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      github = written_config(target)["tracker"]["github"]
      refute Map.has_key?(github, "bot_account")
      refute Map.has_key?(github, "identity_mode")
      refute "GitHub account to add to CODEOWNERS" in input_labels()
    end

    test "a failed token-identity lookup writes no bot_account and never exposes token material",
         %{dir: dir, target: target} do
      secret = "ghp_supersecrettokenvalue"

      d =
        deps(self(), dir, target, %{
          # A viewer-login lookup failure surfaces as a nil default, not a raise.
          github_bot_account_default: fn -> nil end,
          github_token: fn -> secret end
        })

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), d)

      assert written_config(target)["tracker"]["github"]["bot_account"] == "octocat"
      refute File.read!(target) =~ secret
      refute Enum.any?(puts_log(), &(&1 =~ secret))
    end

    test "re-running init preserves an existing bot_account and shows it in the summary",
         %{dir: dir, target: target} do
      d = deps(self(), dir, target, %{github_bot_account_default: fn -> "its-applekid" end})

      # First run writes bot_account: its-applekid.
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), d)
      assert written_config(target)["tracker"]["github"]["bot_account"] == "its-applekid"
      # Drain the first run's recorded prompts/output so the assertions below
      # only observe the resume run.
      _ = puts_log()
      _ = input_labels()
      _ = io_trace()

      # Resume must neither re-ask nor rewrite the tracker; the value stands.
      assert :ok = Init.run(%{force: false}, io(self()), d)

      assert written_config(target)["tracker"]["github"]["bot_account"] == "its-applekid"
      refute Enum.any?(input_labels(), &(&1 in [@bot_account_label, "Your GitHub account"]))
      refute Enum.any?(io_trace(), &(&1 == {:select, @identity_mode_label}))
      assert Enum.any?(puts_log(), &(&1 =~ ~r/bot_account: its-applekid/))
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

    # The scaffold writes the interval into .aiur/config explicitly, so a new
    # install polls at this value rather than at Schema.Polling's default.
    # Leaving it at 30 would have made the widened schema default a no-op for
    # everyone who ran `aiur init`.
    test "the scaffolded poll interval matches the widened schema default", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))
      assert written_config(target)["polling"]["interval_seconds"] == 120
    end

    test "limit prompts carry their helper text as hints; pre-warm has none", %{dir: dir, target: target} do
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

      assert Enum.any?(hints, fn {label, hint} ->
               label == "Max agent duration in minutes" and hint == "Safety checkpoint: none = never auto-pause"
             end)

      # pre-warm no longer carries a hint
      assert {"How many opencode sessions would you like to pre-warm?", nil} in hints
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
end
