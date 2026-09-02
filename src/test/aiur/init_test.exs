defmodule Aiur.InitTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.Labels
  alias Aiur.Init
  alias Aiur.Workflow

  @example_file Path.expand("../../../.aiur/examples/config.example", __DIR__)

  # Every topic the shipped alert examples must keep populated. Kept in sync with
  # the real event names so the scaffolded map fires sounds with zero editing.
  @alert_topics [
    "ticket.*.issue.label.added.agent.todo",
    "ticket.*.issue.label.added.agent.in-progress",
    "ticket.*.issue.label.added.agent.human-review",
    "ticket.*.issue.label.added.agent.rework",
    "ticket.*.pr.merged",
    "ticket.*.issue.state.changed",
    "system.dispatch.todo_capacity_exceeded",
    "system.github_app_token.refresh_failed",
    "system.github_app_token.permission_violation",
    "system.github_app_token.identity_mismatch",
    "system.github_app_token.refresh_recovered",
    "system.dispatch.prewarm_blocked",
    "system.dispatch.prewarm_blocked.resolved",
    "system.dispatch.capacity_starved",
    "system.dispatch.capacity_starved.resolved",
    "system.fleet.capacity.starved",
    "system.fleet.capacity.starved.resolved",
    "system.tracker.auth_preflight_failed",
    "system.tracker.auth_preflight_failed.resolved",
    "ticket.*.agent.error.tokens_exhausted",
    "ticket.*.agent.retry_exhausted",
    "ticket.*.agent.review_feedback_delivery_deferred",
    "ticket.*.agent.paused",
    "ticket.*.agent.paused.resolved",
    "ticket.*.agent.attention.*",
    "ticket.*.agent.attention.*.resolved",
    "ticket.*.agent.unpaused",
    "ticket.*.chat.opened",
    "ticket.*.chat.closed",
    "ticket.*.agent.phase.brainstorm.start",
    "ticket.*.agent.phase.brainstorm.end",
    "ticket.*.agent.phase.plan.start",
    "ticket.*.agent.phase.plan.end",
    "ticket.*.agent.phase.work.start",
    "ticket.*.agent.phase.work.end",
    "ticket.*.agent.phase.review.start",
    "ticket.*.agent.phase.review.end"
  ]

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur-init-test")
    target = Path.join([dir, ".aiur", "config"])
    File.mkdir_p!(Path.dirname(target))
    # The wizard writes `prompt_file: prompt.md`; Workflow.load resolves it, so
    # the file must exist alongside the config for the written config to load.
    File.write!(Path.join([dir, ".aiur", "prompt.md"]), "# agent prompt\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, target: target}
  end

  # Label-keyed scripted io: each prompt looks up its answer by label and
  # falls back to the supplied default, so a test scripts only the answers it
  # cares about regardless of prompt order.
  defp io(parent, answers \\ %{}) do
    %{
      puts: fn message ->
        message = IO.chardata_to_string(message)
        send(parent, {:io_trace, {:puts, message}})
        send(parent, {:puts, message})
        :ok
      end,
      input: fn label, default, _hint ->
        send(parent, {:io_trace, {:input, label}})
        send(parent, {:input_label, label})
        Map.get(Map.get(answers, :input, %{}), label, default)
      end,
      select: fn label, _opts, default ->
        send(parent, {:io_trace, {:select, label}})
        Map.get(Map.get(answers, :select, %{}), label, default)
      end,
      multiselect: fn label, _opts, defaults ->
        Map.get(Map.get(answers, :multiselect, %{}), label, defaults)
      end,
      confirm: fn label, default ->
        send(parent, {:io_trace, {:confirm, label}})
        send(parent, {:confirm, label})
        Map.get(Map.get(answers, :confirm, %{}), label, default)
      end
    }
  end

  defp deps(parent, dir, target, overrides \\ %{}) do
    Map.merge(
      %{
        config_target: fn _location -> target end,
        legacy_config_target: fn _location -> Path.join(dir, ".aiurconfig") end,
        existing_config_path: &existing_path/1,
        load_config: fn t ->
          with {:ok, loaded} <- Workflow.load(t), do: {:ok, loaded.config}
        end,
        read_example: fn -> File.read!(@example_file) end,
        detect_repo: fn -> nil end,
        detect_default_branch: fn _repo -> "main" end,
        setup_repo_state: fn tracker ->
          send(parent, {:repo_state, tracker})
          :ok
        end,
        detect_toolchain: fn -> :none end,
        prewarm_build: fn url, cmd ->
          send(parent, {:prewarm_build, url, cmd})
          {:ok, "/base"}
        end,
        global_alerts_path: fn -> Path.join([dir, "home", ".aiur", "alerts"]) end,
        existing_alerts_path: &existing_path/1,
        write_config: fn t, yaml ->
          File.mkdir_p!(Path.dirname(t))
          File.write!(t, yaml)
          send(parent, {:write, t})
          {:ok, t}
        end,
        append_config: fn t, block ->
          existing = File.read!(t)
          File.write!(t, String.trim_trailing(existing, "\n") <> "\n\n" <> IO.iodata_to_binary(block))
          send(parent, {:append, t})
          {:ok, t}
        end,
        ensure_prompt_file: fn t, pf, _repo ->
          path = Path.expand(pf, Path.dirname(t))

          if File.regular?(path) do
            {:exists, path}
          else
            File.write!(path, "# prompt\n")
            {:created, path}
          end
        end,
        ensure_aiurhooks: fn t ->
          path = Path.join(Path.dirname(t), "hooks")

          if File.regular?(path) do
            {:exists, path}
          else
            File.write!(path, "after_create: echo created\n")
            {:created, path}
          end
        end,
        ensure_alerts: &ensure_alerts_for_test/2,
        ensure_prewarm_file: fn t, cmd ->
          path = Path.join(Path.dirname(t), "prewarm")
          File.write!(path, cmd <> "\n")
          send(parent, {:prewarm_file, cmd})
          {:created, path}
        end,
        add_gitignore_entry: fn entry ->
          path = Path.join(dir, ".gitignore")
          existing = if File.regular?(path), do: File.read!(path), else: ""

          if existing |> String.split("\n") |> Enum.member?(entry) do
            {:exists, path}
          else
            File.write!(path, existing <> entry <> "\n")
            send(parent, {:gitignore, entry})
            {:added, path}
          end
        end,
        ensure_env: fn content ->
          env_path = Path.join(dir, ".env")

          if File.regular?(env_path) do
            {:exists, env_path}
          else
            File.write!(env_path, content)
            {:created, env_path}
          end
        end,
        check_agent_auth: fn _kind -> :ok end,
        install_claude_app_server: fn _spec -> :ok end,
        claude_registry_version: fn -> {:ok, "1.1.0"} end,
        claude_version: fn -> {:ok, "1.1.0"} end,
        # No installed CLI to ask in the wizard tests; discovery degrading to an
        # error is the offline path, and init must finish through it.
        discover_models: fn _backend -> {:error, :offline} end,
        repo_root: fn -> dir end,
        github_login: fn -> "octocat" end,
        github_bot_account_default: fn -> nil end,
        github_token: fn -> nil end,
        check_ci_readiness: fn _tracker -> {:ok, %{ready?: true, base_branch: "main", required_checks: ["ci / required"]}} end,
        list_labels: fn _tracker -> {:ok, []} end,
        create_labels: fn tracker, labels ->
          send(parent, {:labels, tracker, labels})
          :ok
        end
      },
      overrides
    )
  end

  defp existing_path(path) do
    if File.regular?(path), do: path
  end

  defp ensure_alerts_for_test(target, source_path) do
    path = Path.join(Path.dirname(target), "alerts")

    if File.regular?(path) do
      {:exists, path}
    else
      write_alerts_for_test(path, source_path)
      {:created, path}
    end
  end

  defp write_alerts_for_test(path, source_path) when is_binary(source_path) do
    File.cp!(source_path, path)
  end

  defp write_alerts_for_test(path, _source_path) do
    File.write!(path, "alerts: {}\n")
  end

  defp written_config(path) do
    assert {:ok, loaded} = Workflow.load(path)
    loaded.config
  end

  defp assert_filled_alert_template(template, sound_path_regex) do
    assert {:ok, %{"alerts" => alerts}} = YamlElixir.read_from_string(template)
    assert alerts |> Map.keys() |> Enum.sort() == Enum.sort(@alert_topics)

    for topic <- @alert_topics do
      assert %{"message" => message, "sound" => sounds} = Map.fetch!(alerts, topic)
      assert is_binary(message) and message != ""
      assert is_list(sounds) and sounds != []
      assert Enum.all?(sounds, &Regex.match?(sound_path_regex, &1))
    end
  end

  defp puts_log(acc \\ []) do
    receive do
      {:puts, msg} -> puts_log([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp io_trace(acc \\ []) do
    receive do
      {:io_trace, event} -> io_trace([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Resume init against an enabled-prewarm config whose first warm-base build
  # fails with `reason`, returning the joined operator-facing output.
  defp run_prewarm_failure(parent, dir, target, reason) do
    File.write!(target, """
    tracker:
      kind: github
      base_branch: main
      github:
        repo: octo/repo
    agent:
      kind: claude
    prewarm:
      enabled: true
      base_build: mise exec -- npm ci && mise exec -- npm run build
    """)

    d = deps(parent, dir, target, %{prewarm_build: fn _url, _cmd -> {:error, reason} end})
    assert :ok = Init.run(%{force: false}, io(parent), d)
    Enum.join(puts_log(), "\n")
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

  defp select_labels(acc \\ []) do
    receive do
      {:select_label, label} -> select_labels([label | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Flattened labels across every staged create_labels call.
  defp labels_created(acc \\ []) do
    receive do
      {:labels, _tracker, labels} -> labels_created(acc ++ labels)
    after
      0 -> acc
    end
  end

  defp codeowners_path(dir), do: Path.join([dir, ".github", "CODEOWNERS"])

  # Prompts the wizard asked the operator to confirm (one per stage that has
  # labels to create).
  defp confirm_prompts(acc \\ []) do
    receive do
      {:confirm, label} -> confirm_prompts([label | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @duration_label "Max agent duration in minutes"

  @location_label "Where will you store aiur settings for this project?"

  @reuse_global_alerts_label "Found an existing alerts file at ~/.aiur/alerts — copy it into this repo's .aiur/alerts?"

  @prewarm_command_label "Use this base build command?"
  @base_build_command_label "Base build command"
  @alert_sounds_label "Add sound effects for alerts (e.g. an agent is stuck or needs your input)?"
  @gitignore_label "Add .aiur/ to .gitignore?"

  defp github_answers(overrides \\ %{}) do
    base = %{
      select: %{@location_label => "repo", "Issue tracker" => "github"},
      input: %{"GitHub repo (owner/name)" => "octo/repo"},
      multiselect: %{"Which agents to support" => ["claude"]}
    }

    Map.merge(base, overrides, fn _k, v1, v2 -> Map.merge(v1, v2) end)
  end

  describe "CODEOWNERS trust setup" do
    test "no-file + create writes CODEOWNERS and adds the operator", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))

      codeowners = File.read!(codeowners_path(dir))
      assert codeowners =~ "aiur uses CODEOWNERS"
      assert codeowners =~ "* @octocat"

      log = Enum.join(puts_log(), "\n")
      assert log =~ "aiur uses CODEOWNERS to determine which GitHub accounts it will trust"
    end

    test "no-file + decline leaves the repo unchanged", %{dir: dir, target: target} do
      answers =
        github_answers(%{
          confirm: %{"Create .github/CODEOWNERS for aiur's GitHub trust checks?" => false}
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))

      refute File.exists?(codeowners_path(dir))
      assert Enum.any?(puts_log(), &(&1 =~ "Skipped CODEOWNERS"))
    end

    test "existing-file + add-self appends the operator without clobbering owners", %{dir: dir, target: target} do
      File.mkdir_p!(Path.join(dir, ".github"))
      File.write!(codeowners_path(dir), "* @platform-team # default owners\n")

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))

      assert File.read!(codeowners_path(dir)) == "* @platform-team @octocat # default owners\n"
      refute Enum.any?(confirm_prompts(), &(&1 =~ "Create .github/CODEOWNERS"))
    end

    test "existing-file + already-present is a no-op with no CODEOWNERS prompt spam", %{dir: dir, target: target} do
      File.write!(
        target,
        """
        tracker:
          kind: github
          base_branch: main
          github:
            repo: octo/repo
        agent:
          kind: claude
        prewarm:
          enabled: false
        """
      )

      File.mkdir_p!(Path.join(dir, ".github"))
      File.write!(codeowners_path(dir), "* @OctoCat\n")

      assert :ok = Init.run(%{force: false}, io(self()), deps(self(), dir, target))

      assert File.read!(codeowners_path(dir)) == "* @OctoCat\n"
      refute "GitHub account to add to CODEOWNERS" in input_labels()
      refute Enum.any?(confirm_prompts(), &(&1 =~ "CODEOWNERS"))
    end

    test "resume on an existing config backfills missing CODEOWNERS", %{dir: dir, target: target} do
      File.write!(
        target,
        """
        tracker:
          kind: github
          base_branch: main
          github:
            repo: octo/repo
        agent:
          kind: claude
        prewarm:
          enabled: false
        """
      )

      assert :ok = Init.run(%{force: false}, io(self()), deps(self(), dir, target))

      assert File.read!(codeowners_path(dir)) =~ "* @octocat"
    end
  end

  describe "pre-warm opt-in" do
    test "use builds immediately before alerts and gitignore, then writes the command", %{dir: dir, target: target} do
      d =
        deps(self(), dir, target, %{
          detect_toolchain: fn ->
            {:ok, %{language: :elixir, build_root: "src", command: "mise exec -- mix compile"}}
          end
        })

      answers = github_answers(%{select: %{@prewarm_command_label => "use"}})

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      events = io_trace()

      assert [{:select, @prewarm_command_label}, {:puts, build_message} | _] =
               Enum.drop_while(events, &(&1 != {:select, @prewarm_command_label}))

      assert build_message =~ "Building the warm base now"

      assert [
               {:puts, ^build_message},
               {:confirm, @alert_sounds_label},
               {:confirm, @gitignore_label}
             ] =
               Enum.filter(events, fn
                 {:puts, message} -> message =~ "Building the warm base now"
                 {:confirm, label} -> label in [@alert_sounds_label, @gitignore_label]
                 _event -> false
               end)

      # init writes the command to the sibling .aiur/prewarm script and runs the
      # first warm-base build on opt-in
      assert_received {:prewarm_build, _url, "mise exec -- mix compile"}
      assert File.read!(Path.join([dir, ".aiur", "prewarm"])) == "mise exec -- mix compile\n"

      config = File.read!(target)
      assert config =~ "enabled: true"
      assert config =~ "base_build_file: prewarm"
      refute config =~ ~s(base_build: ")
    end

    test "edit builds immediately after the edited command is accepted", %{dir: dir, target: target} do
      edited_command = "mise exec -- mix deps.get && mise exec -- mix compile"

      d =
        deps(self(), dir, target, %{
          detect_toolchain: fn ->
            {:ok, %{language: :elixir, build_root: "src", command: "mise exec -- mix compile"}}
          end
        })

      answers =
        github_answers(%{
          select: %{@prewarm_command_label => "edit"},
          input: %{@base_build_command_label => edited_command}
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      events = io_trace()

      assert [
               {:select, @prewarm_command_label},
               {:input, @base_build_command_label},
               {:puts, build_message}
               | _rest
             ] = Enum.drop_while(events, &(&1 != {:select, @prewarm_command_label}))

      assert build_message =~ "Building the warm base now"
      assert_received {:prewarm_build, _url, ^edited_command}
      assert File.read!(Path.join([dir, ".aiur", "prewarm"])) == edited_command <> "\n"
    end

    test "skip does not build or write a prewarm command", %{dir: dir, target: target} do
      d =
        deps(self(), dir, target, %{
          detect_toolchain: fn ->
            {:ok, %{language: :elixir, build_root: "src", command: "mise exec -- mix compile"}}
          end
        })

      answers = github_answers(%{select: %{@prewarm_command_label => "skip"}})

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      events = io_trace()

      assert [{:select, @prewarm_command_label}, {:confirm, @alert_sounds_label} | _] =
               Enum.drop_while(events, &(&1 != {:select, @prewarm_command_label}))

      refute Enum.any?(events, fn
               {:puts, message} -> message =~ "Building the warm base now"
               _event -> false
             end)

      refute_received {:prewarm_build, _url, _command}
      refute_received {:prewarm_file, _command}
      refute File.exists?(Path.join([dir, ".aiur", "prewarm"]))

      config = File.read!(target)
      assert config =~ "enabled: false"
      refute config =~ "base_build_file: prewarm"
    end

    test "detection miss prints a fallback prompt and leaves prewarm disabled", %{dir: dir, target: target} do
      d = deps(self(), dir, target, %{detect_toolchain: fn -> :none end})

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), d)

      log = Enum.join(puts_log(), "\n")
      assert log =~ "paste this to your coding agent"
      assert log =~ "agent-orchestration"
      assert log =~ "copy-on-write"
      assert log =~ "mise exec --"
      assert log =~ "Node/pnpm workspaces"
      assert log =~ "Elixir app in src"
      assert log =~ "prewarm:"
      assert log =~ "base_build:"
      assert log =~ "Run it a second time unchanged"

      config = File.read!(target)
      assert config =~ "enabled: false"
      refute config =~ "base_build:"
    end

    test "ambiguous detection discloses the candidates and routes to the AI prompt",
         %{dir: dir, target: target} do
      d =
        deps(self(), dir, target, %{
          detect_toolchain: fn ->
            {:ambiguous, [%{language: :node, build_root: "."}, %{language: :swift, build_root: "watchos"}]}
          end
        })

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), d)

      log = Enum.join(puts_log(), "\n")
      assert log =~ "multiple build roots"
      assert log =~ "node (.)"
      assert log =~ "swift (watchos)"
      assert log =~ "paste this to your coding agent"

      config = File.read!(target)
      assert config =~ "enabled: false"
      refute config =~ "base_build:"
    end

    test "declining the opt-in leaves prewarm disabled", %{dir: dir, target: target} do
      d =
        deps(self(), dir, target, %{
          detect_toolchain: fn -> {:ok, %{language: :elixir, build_root: ".", command: "x"}} end
        })

      answers =
        github_answers(%{
          confirm: %{"Keep a pre-warmed copy of the configured base branch so agents skip cloning + building?" => false}
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      config = File.read!(target)
      assert config =~ "enabled: false"
      refute config =~ "base_build:"
    end
  end

  describe "alert sound opt-in" do
    test "accepting writes an enabled alerts block with OS-default sounds", %{dir: dir, target: target} do
      d = deps(self(), dir, target, %{})

      answers =
        github_answers(%{
          confirm: %{
            "Add sound effects for alerts (e.g. an agent is stuck or needs your input)?" => true
          }
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      config = File.read!(target)
      # Scope the assertion to the alerts block so it can't pass on prewarm's
      # `enabled:` line.
      assert config =~ ~r/alerts:\n\s+enabled: true/
      assert config =~ "use_os_default_sounds: true"
    end

    test "declining writes a disabled alerts block", %{dir: dir, target: target} do
      d = deps(self(), dir, target, %{})

      # The confirm mock defaults unknown prompts to their default (false), so
      # the standard github answers already decline the alerts opt-in.
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), d)

      config = File.read!(target)
      assert config =~ ~r/alerts:\n\s+enabled: false/
      assert config =~ "use_os_default_sounds: false"
    end

    test "declining OS defaults selects the custom .aiur/alerts mapping", %{dir: dir, target: target} do
      d = deps(self(), dir, target, %{})

      answers =
        github_answers(%{
          confirm: %{
            "Add sound effects for alerts (e.g. an agent is stuck or needs your input)?" => true,
            "Use the built-in OS default sounds? (No = play the custom .aiur/alerts mapping)" => false
          }
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      config = File.read!(target)
      assert config =~ ~r/alerts:\n\s+enabled: true/
      assert config =~ "use_os_default_sounds: false"
    end

    test "copies an existing global alerts file when accepted", %{dir: dir, target: target} do
      source = Path.join([dir, "home", ".aiur", "alerts"])
      File.mkdir_p!(Path.dirname(source))
      File.write!(source, "ticket.*.attention: Glass\n")
      d = deps(self(), dir, target, %{})

      answers =
        github_answers(%{
          confirm: %{
            "Add sound effects for alerts (e.g. an agent is stuck or needs your input)?" => true,
            @reuse_global_alerts_label => true
          }
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      assert File.read!(Path.join(Path.dirname(target), "alerts")) == "ticket.*.attention: Glass\n"
    end

    test "scaffolds the default alerts file when global reuse is declined", %{dir: dir, target: target} do
      source = Path.join([dir, "home", ".aiur", "alerts"])
      File.mkdir_p!(Path.dirname(source))
      File.write!(source, "ticket.*.attention: Glass\n")
      d = deps(self(), dir, target, %{})

      answers =
        github_answers(%{
          confirm: %{
            "Add sound effects for alerts (e.g. an agent is stuck or needs your input)?" => true,
            @reuse_global_alerts_label => false
          }
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      assert File.read!(Path.join(Path.dirname(target), "alerts")) == "alerts: {}\n"
    end

    test "scaffolds the default alerts file when no global alerts file exists", %{dir: dir, target: target} do
      d = deps(self(), dir, target, %{})

      answers =
        github_answers(%{
          confirm: %{
            "Add sound effects for alerts (e.g. an agent is stuck or needs your input)?" => true
          }
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      assert File.read!(Path.join(Path.dirname(target), "alerts")) == "alerts: {}\n"
      refute @reuse_global_alerts_label in confirm_prompts()
    end

    test "global init treats reusing the existing global alerts file as a no-op", %{dir: dir} do
      target = Path.join([dir, "home", ".aiur", "config"])
      source = Path.join([dir, "home", ".aiur", "alerts"])
      File.mkdir_p!(Path.dirname(source))
      File.write!(source, "ticket.*.attention: Glass\n")
      d = deps(self(), dir, target, %{})

      answers =
        github_answers(%{
          select: %{@location_label => "global"},
          confirm: %{
            "Add sound effects for alerts (e.g. an agent is stuck or needs your input)?" => true,
            @reuse_global_alerts_label => true
          }
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      assert File.read!(source) == "ticket.*.attention: Glass\n"
    end

    test "scaffolds an extensionless .aiur/alerts next to the config", %{dir: dir, target: target} do
      d = deps(self(), dir, target, %{})

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), d)

      # The generated config points at the sibling map by relative name, and the
      # map file is scaffolded next to the config (no extension).
      assert File.read!(target) =~ ~r/^\s*alerts_file: alerts\s*(#.*)?$/m
      assert File.regular?(Path.join(Path.dirname(target), "alerts"))
    end

    test "alert examples are concise and fully populated with platform sounds" do
      macos = Init.alerts_template({:unix, :darwin})
      linux = Init.alerts_template({:unix, :linux})

      # Source-grouped section headers stay; the big explanatory block is gone.
      for template <- [macos, linux] do
        assert template =~ "Ticket-powered alerts"
        assert template =~ "Agent-powered alerts"
        assert template =~ "AI-powered alerts"
        refute template =~ "Sound filenames"
        refute template =~ "Topic / glob matching"

        # Phase milestones publish as `ticket.<id>.agent.phase.<phase>.<edge>`
        # (agent_runner prefixes the bare `phase.work.start` name). The glob must
        # carry the `.phase.` segment or the sound never fires.
        assert template =~ "ticket.*.agent.phase.work.start"
        refute template =~ ~r/"ticket\.\*\.agent\.work\.start"/
        assert template =~ "ticket.*.agent.review_feedback_delivery_deferred"
      end

      assert_filled_alert_template(macos, ~r{\A/System/Library/Sounds/.+\.aiff\z})
      assert_filled_alert_template(linux, ~r{\A/usr/share/sounds/freedesktop/stereo/.+\.oga\z})
    end

    test "alert template selection follows the host OS family" do
      macos = Init.alerts_template({:unix, :darwin})
      linux = Init.alerts_template({:unix, :linux})

      assert macos =~ "/System/Library/Sounds/Glass.aiff"
      refute macos =~ "/usr/share/sounds/freedesktop"

      assert linux =~ "/usr/share/sounds/freedesktop/stereo/message-new-instant.oga"
      refute linux =~ "/System/Library/Sounds"

      # Non-macOS Unix and unknown hosts fall back to the Linux example.
      assert Init.alerts_template({:unix, :freebsd}) == linux
      assert Init.alerts_template(:unknown) == linux
    end
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
      File.write!(target, """
      prewarm:
        enabled: false
      elevenlabs:
        enabled: false
      """)

      prewarm_prompt =
        "Keep a pre-warmed copy of the configured base branch so agents skip cloning + building?"

      elevenlabs_prompt = "Enable Stream Deck voice input with ElevenLabs speech-to-text?"

      answers =
        github_answers(%{
          confirm: %{prewarm_prompt => true, elevenlabs_prompt => true},
          select: %{@prewarm_command_label => "use"}
        })

      d =
        deps(self(), dir, target, %{
          detect_toolchain: fn ->
            {:ok, %{language: :elixir, build_root: "src", command: "mise exec -- mix compile"}}
          end
        })

      assert :ok = Init.run(%{force: true}, io(self(), answers), d)

      prompts = confirm_prompts()
      assert prewarm_prompt in prompts
      assert elevenlabs_prompt in prompts

      config = written_config(target)
      assert config["prewarm"]["enabled"] == true
      assert config["elevenlabs"]["enabled"] == true
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
      _ = confirm_prompts()

      # Re-run with no scripted intro answers: it must resume, not re-ask.
      assert :ok = Init.run(%{force: false}, io(self()), d)

      refute Enum.any?(input_labels(), &(&1 =~ ~r/Where should agents work/))

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/Saved selections/i))
      # The summary lists every saved selection, not just the first few.
      assert Enum.any?(log, &(&1 =~ ~r/repo: octo\/repo/))
      assert Enum.any?(log, &(&1 =~ ~r/routing: 1:/))
      assert Enum.any?(log, &(&1 =~ ~r/permission_mode: bypassPermissions/))
      assert Enum.any?(log, &(&1 =~ ~r/workspace_root:/))
      assert Enum.any?(log, &(&1 =~ ~r/polling_interval_seconds: 120/))
      assert Enum.any?(log, &(&1 =~ ~r/prewarm: declined/))
      assert Enum.any?(log, &(&1 =~ ~r/elevenlabs_voice_input: declined/))
      refute Enum.any?(confirm_prompts(), &(&1 =~ ~r/ElevenLabs speech-to-text/))
    end

    test "resume never runs a CLI auth check for the claude-repl transport", %{
      dir: dir,
      target: target
    } do
      parent = self()
      # existing_config_path only needs the file to exist; load_config is stubbed.
      File.write!(target, "placeholder")

      config = %{
        "tracker" => %{"kind" => "memory", "base_branch" => "main"},
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

    test "resume skips the location question when a config already exists", %{
      dir: dir,
      target: target
    } do
      parent = self()
      d = deps(parent, dir, target)
      # First run writes a config.
      assert :ok = Init.run(%{force: false}, io(parent, github_answers()), d)
      _ = puts_log()

      recording = %{
        io(parent)
        | select: fn label, _opts, default ->
            send(parent, {:select_label, label})
            default
          end
      }

      assert :ok = Init.run(%{force: false}, recording, d)

      refute Enum.any?(select_labels(), &(&1 =~ ~r/where will you store/i))
      assert Enum.any?(puts_log(), &(&1 =~ ~r/Saved selections/i))
    end

    test "refuses a legacy root config with the canonical destination", %{dir: dir, target: target} do
      legacy = Path.join(dir, ".aiurconfig")
      File.write!(legacy, "tracker:\n  kind: memory\n  base_branch: main\nagent:\n  kind: claude\n")

      assert {:error, message} = Init.run(%{force: false}, io(self()), deps(self(), dir, target))
      assert message =~ "#{legacy} is no longer supported"
      assert message =~ "Move it to #{target}"
      assert message =~ "relative prompt_file and hooks_file paths"
      refute_received {:repo_state, _tracker}
    end

    test "resume verifies an existing enabled prewarm config", %{target: target} do
      File.write!(
        target,
        """
        tracker:
          kind: github
          base_branch: main
          github:
            repo: octo/repo
        agent:
          kind: claude
        prewarm:
          enabled: true
          base_build: mise exec -- npm ci && mise exec -- npm run build
        """
      )

      assert :ok = Init.run(%{force: false}, io(self()), deps(self(), Path.dirname(target), target))

      assert_received {:prewarm_build, "https://github.com/octo/repo.git", "mise exec -- npm ci && mise exec -- npm run build"}

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ "Building the warm base now"))
      assert Enum.any?(log, &(&1 =~ "Warm base ready"))
    end
  end

  describe "warm-base failure report" do
    test "auth failure gives token guidance + an AI prompt embedding the captured output",
         %{dir: dir, target: target} do
      out = "fatal: Authentication failed for 'https://github.com/octo/repo.git/'"
      log = run_prewarm_failure(self(), dir, target, {:repo_base_clone_failed, 128, out})

      assert log =~ "Warm base build failed"
      assert log =~ "authentication failure"
      assert log =~ "GITHUB_TOKEN"
      # AI handoff present and embeds the real git error
      assert log =~ "paste this to your coding agent"
      assert log =~ "Authentication failed for"
      assert log =~ "retries automatically on the next"
    end

    test "build failure points at base_build and routes to the AI prompt",
         %{dir: dir, target: target} do
      log = run_prewarm_failure(self(), dir, target, {:base_build_failed, 1, "npm ERR! boom"})

      assert log =~ "base_build command failed"
      assert log =~ "paste this to your coding agent"
      assert log =~ "npm ERR! boom"
      refute log =~ "authentication failure"
    end

    test "a non-auth clone error gives clone guidance, not auth guidance",
         %{dir: dir, target: target} do
      log =
        run_prewarm_failure(self(), dir, target, {:repo_base_clone_failed, 128, "fatal: repository not found"})

      assert log =~ "warm-base clone of"
      refute log =~ "authentication failure"
      assert log =~ "paste this to your coding agent"
    end

    test "a non-tuple failure reason still reports gracefully (no crash)",
         %{dir: dir, target: target} do
      # classify -> :other and failure_output -> inspect fallback; must not raise.
      log = run_prewarm_failure(self(), dir, target, {:build_crashed, :killed})

      assert log =~ "Warm base build failed"
      assert log =~ "paste this to your coding agent"
      assert log =~ "retries automatically on the next"
      refute log =~ "authentication failure"
    end
  end

  describe "resume backfill of new config sections (#411)" do
    # A config written before the prewarm block existed.
    @legacy_yaml "tracker:\n  kind: github\n  base_branch: main\n  github:\n    repo: octo/repo\nagent:\n  kind: claude\n"

    test "offers a missing registered section and appends it on opt-in", %{dir: dir, target: target} do
      File.write!(target, @legacy_yaml)

      d =
        deps(self(), dir, target, %{
          detect_toolchain: fn ->
            {:ok, %{language: :elixir, build_root: ".", command: "mise exec -- mix compile"}}
          end
        })

      # confirm "Keep a pre-warmed copy...?" defaults to true; accept the command.
      answers = %{select: %{"Use this base build command?" => "use"}}
      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      # Appended (not regenerated): original keys preserved, prewarm block added.
      config = File.read!(target)
      assert config =~ "repo: octo/repo"
      assert config =~ "prewarm:"
      assert config =~ "enabled: true"
      # The command lives in the sibling `.aiur/prewarm` script, mirroring fresh
      # setup; the appended block points at it via base_build_file.
      assert config =~ "base_build_file: prewarm"
      refute config =~ ~s(base_build: ")
      assert_received {:prewarm_file, "mise exec -- mix compile"}
      assert_received {:append, ^target}
      # Reuses the existing first-build flow.
      assert_received {:prewarm_build, _url, "mise exec -- mix compile"}
    end

    test "does not prompt when the registered section is already present", %{dir: dir, target: target} do
      d = deps(self(), dir, target)
      # First run writes a config that already includes the prewarm block.
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), d)
      _ = puts_log()
      _ = confirm_prompts()

      assert :ok = Init.run(%{force: false}, io(self()), d)

      refute Enum.any?(confirm_prompts(), &(&1 =~ ~r/pre-warmed copy/))
      refute_received {:append, ^target}
    end

    test "does not run the section's first build when the append fails", %{dir: dir, target: target} do
      File.write!(target, @legacy_yaml)

      d =
        deps(self(), dir, target, %{
          detect_toolchain: fn ->
            {:ok, %{language: :elixir, build_root: ".", command: "mise exec -- mix compile"}}
          end,
          append_config: fn _t, _block -> {:error, :eacces} end
        })

      answers = %{select: %{"Use this base build command?" => "use"}}
      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      # The append failed, so the warm base must not be built (no orphaned base).
      refute_received {:prewarm_build, _url, _cmd}
      assert Enum.any?(puts_log(), &(&1 =~ ~r/Couldn't update/))
    end

    test "declining the offer persists disabled prewarm and a later resume skips the prompt", %{dir: dir, target: target} do
      File.write!(target, @legacy_yaml)

      d =
        deps(self(), dir, target, %{
          detect_toolchain: fn -> {:ok, %{language: :elixir, build_root: ".", command: "x"}} end
        })

      answers = %{
        confirm: %{"Keep a pre-warmed copy of the configured base branch so agents skip cloning + building?" => false}
      }

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      assert File.read!(target) =~ "prewarm:\n  enabled: false"
      assert_received {:append, ^target}
      refute_received {:prewarm_build, _url, _cmd}

      _ = confirm_prompts()
      assert :ok = Init.run(%{force: false}, io(self()), d)
      refute Enum.any?(confirm_prompts(), &(&1 =~ ~r/pre-warmed copy/))
      refute_received {:prewarm_build, _url, _cmd}
    end
  end

  describe "parse_dotenv/1" do
    test "parses KEY=VALUE pairs, skipping comments, blanks, and empty values" do
      content = """
      # a comment
      GITHUB_TOKEN=ghp_abc123

      QUOTED="with-quotes"
      SINGLE='single'
      EMPTY=
      NO_EQUALS_LINE
      SPACED = padded
      """

      pairs = Init.parse_dotenv(content)

      assert {"GITHUB_TOKEN", "ghp_abc123"} in pairs
      assert {"QUOTED", "with-quotes"} in pairs
      assert {"SINGLE", "single"} in pairs
      assert {"SPACED", "padded"} in pairs
      refute Enum.any?(pairs, fn {k, _} -> k == "EMPTY" end)
      refute Enum.any?(pairs, fn {k, _} -> k == "NO_EQUALS_LINE" end)
    end
  end

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
    @bot_account_label "GitHub account Aiur's agents post as (bot_account)"

    test "persists the token's detected login accepted as the default", %{dir: dir, target: target} do
      d = deps(self(), dir, target, %{github_bot_account_default: fn -> "its-applekid" end})

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), d)

      assert written_config(target)["tracker"]["github"]["bot_account"] == "its-applekid"
    end

    test "persists a normalized custom login over the default", %{dir: dir, target: target} do
      answers = github_answers(%{input: %{@bot_account_label => "@Custom-Bot"}})
      d = deps(self(), dir, target, %{github_bot_account_default: fn -> "octocat" end})

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      assert written_config(target)["tracker"]["github"]["bot_account"] == "custom-bot"
    end

    test "explains the credential-vs-identity distinction during setup", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))

      log = Enum.join(puts_log(), "\n")
      assert log =~ "GITHUB_TOKEN"
      assert log =~ "github.bot_account"
      assert log =~ ~r/dedicated bot account/i
    end

    test "a blank answer skips bot_account and writes no key", %{dir: dir, target: target} do
      answers = github_answers(%{input: %{@bot_account_label => ""}})
      d = deps(self(), dir, target, %{github_bot_account_default: fn -> nil end})

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      refute Map.has_key?(written_config(target)["tracker"]["github"], "bot_account")
      assert Enum.any?(puts_log(), &(&1 =~ ~r/Skipped bot_account/))
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

      refute Map.has_key?(written_config(target)["tracker"]["github"], "bot_account")
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

      # Resume must neither re-ask nor rewrite the tracker; the value stands.
      assert :ok = Init.run(%{force: false}, io(self()), d)

      assert written_config(target)["tracker"]["github"]["bot_account"] == "its-applekid"
      refute Enum.any?(input_labels(), &(&1 == @bot_account_label))
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
      assert opts == ["claude", "codex", "kimi", "openrouter", "fake"]
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
    test "scaffolds only .env and walks through the bot-account token", %{dir: dir, target: target} do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))

      assert File.read!(Path.join(dir, ".env")) == "GITHUB_TOKEN=\n"
      refute File.exists?(Path.join(dir, ".env.example"))

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/bot account/i))
      assert Enum.any?(log, &(&1 =~ "settings/tokens"))
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

    test "no-token instructions give explicit classic and fine-grained click-paths", %{
      dir: dir,
      target: target
    } do
      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps(self(), dir, target))

      log = puts_log()
      joined = Enum.join(log, "\n")

      assert joined =~ "Generate new token (classic)"
      assert joined =~ "Administration: Read-only"
      assert joined =~ "repo` scope"
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

  describe "claude app-server install" do
    @missing_claude {:error, "aiur-claude not found on PATH — install it with: npm install -g aiur-claude"}

    test "installs aiur-claude when the command is missing, then clears the warning", %{
      dir: dir,
      target: target
    } do
      parent = self()
      {:ok, present} = Agent.start_link(fn -> false end)

      d =
        deps(parent, dir, target, %{
          check_agent_auth: fn
            "claude" -> if Agent.get(present, & &1), do: :ok, else: @missing_claude
            _ -> :ok
          end,
          claude_version: fn -> if Agent.get(present, & &1), do: {:ok, "1.1.0"}, else: :missing end,
          install_claude_app_server: fn spec ->
            send(parent, {:install, spec})
            Agent.update(present, fn _ -> true end)
            :ok
          end
        })

      assert :ok = Init.run(%{force: false}, io(parent, github_answers()), d)

      assert_received {:install, "aiur-claude@1.1.0"}
      refute Enum.any?(puts_log(), &(&1 =~ ~r/not found on PATH/))
    end

    test "skips the install when aiur-claude already resolves", %{dir: dir, target: target} do
      parent = self()

      d =
        deps(parent, dir, target, %{
          check_agent_auth: fn _kind -> :ok end,
          install_claude_app_server: fn spec ->
            send(parent, {:install, spec})
            :ok
          end
        })

      assert :ok = Init.run(%{force: false}, io(parent, github_answers()), d)

      refute_received {:install, _spec}
    end

    test "never installs when claude is not selected", %{dir: dir, target: target} do
      parent = self()
      answers = github_answers(%{multiselect: %{"Which agents to support" => ["codex"]}})

      d =
        deps(parent, dir, target, %{
          check_agent_auth: fn _kind -> :ok end,
          install_claude_app_server: fn spec ->
            send(parent, {:install, spec})
            :ok
          end
        })

      assert :ok = Init.run(%{force: false}, io(parent, answers), d)

      refute_received {:install, _spec}
    end

    test "an aiur-claude older than the minimum is upgraded before init completes", %{
      dir: dir,
      target: target
    } do
      parent = self()
      {:ok, versions} = Agent.start_link(fn -> [{:ok, "1.0.0"}, {:ok, "1.1.0"}] end)

      d =
        deps(parent, dir, target, %{
          claude_version: fn -> Agent.get_and_update(versions, fn [next | rest] -> {next, rest} end) end,
          install_claude_app_server: fn spec ->
            send(parent, {:install, spec})
            :ok
          end
        })

      assert :ok = Init.run(%{force: false}, io(parent, github_answers()), d)

      assert_received {:install, "aiur-claude@1.1.0"}
    end

    test "a current aiur-claude prints no version warning", %{dir: dir, target: target} do
      parent = self()
      d = deps(parent, dir, target, %{claude_version: fn -> {:ok, "1.1.0"} end})

      assert :ok = Init.run(%{force: false}, io(parent, github_answers()), d)

      refute Enum.any?(puts_log(), &(&1 =~ ~r/aiur-claude/ and &1 =~ ~r/older than/))
    end

    test "a failed install stops init before the final setup screen", %{
      dir: dir,
      target: target
    } do
      parent = self()

      d =
        deps(parent, dir, target, %{
          claude_version: fn -> :missing end,
          install_claude_app_server: fn _spec -> {:error, "npm not found on PATH"} end
        })

      assert {:error, message} = Init.run(%{force: false}, io(parent, github_answers()), d)

      assert message =~ "couldn't install aiur-claude"
      refute Enum.any?(puts_log(), &(&1 =~ "aiur is set up"))
    end

    test "an insufficient post-install version stops init", %{dir: dir, target: target} do
      parent = self()
      {:ok, versions} = Agent.start_link(fn -> [:missing, {:ok, "1.0.0"}] end)

      d =
        deps(parent, dir, target, %{
          claude_version: fn -> Agent.get_and_update(versions, fn [next | rest] -> {next, rest} end) end,
          claude_registry_version: fn -> {:ok, "1.0.0"} end,
          install_claude_app_server: fn _spec -> :ok end
        })

      assert {:error, message} = Init.run(%{force: false}, io(parent, github_answers()), d)
      assert message =~ "installed aiur-claude 1.0.0"
      assert message =~ "requires 1.1.0 or newer"
      refute Enum.any?(puts_log(), &(&1 =~ "aiur is set up"))
    end

    test "an unreadable existing version is preserved and stops init before the final screen", %{
      dir: dir,
      target: target
    } do
      parent = self()

      answers =
        github_answers(%{
          select: %{"Issue tracker" => "linear"},
          input: %{"Linear API key" => "lin_test", "Linear project slug" => "project"}
        })

      d =
        deps(parent, dir, target, %{
          claude_version: fn -> {:error, "unreadable --version output"} end,
          claude_registry_version: fn -> flunk("registry must not be queried") end,
          install_claude_app_server: fn _spec -> flunk("existing install must not be replaced") end
        })

      assert {:error, message} = Init.run(%{force: false}, io(parent, answers), d)
      assert message =~ "could not be verified"
      assert message =~ "left unchanged"
      refute Enum.any?(puts_log(), &(&1 =~ "aiur is set up"))
    end

    test "a failed install doesn't also print a version warning", %{dir: dir, target: target} do
      parent = self()

      d =
        deps(parent, dir, target, %{
          install_claude_app_server: fn _spec -> {:error, "npm not found on PATH"} end,
          claude_version: fn -> :missing end
        })

      assert {:error, _message} = Init.run(%{force: false}, io(parent, github_answers()), d)

      refute Enum.any?(puts_log(), &(&1 =~ ~r/couldn't check the aiur-claude version/))
    end
  end
end
