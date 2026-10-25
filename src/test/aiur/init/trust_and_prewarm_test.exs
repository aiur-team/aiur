defmodule Aiur.Init.TrustAndPrewarmTest do
  use Aiur.InitCase

  @prewarm_command_label "Use this base build command?"
  @base_build_command_label "Base build command"
  @alert_sounds_label "Add sound effects for alerts (e.g. an agent is stuck or needs your input)?"
  @gitignore_label "Add .aiur/ to .gitignore?"

  defmodule SyntheticInit do
    @spec prompt(Aiur.Init.io()) :: map()
    def prompt(io), do: %{region: io.input.("Synthetic backend region", "west", nil)}

    @spec config(map()) :: map()
    def config(%{region: region}), do: %{"region" => region}
  end

  test "fresh Muse init requires explicit workspace trust and writes native settings", %{dir: dir, target: target} do
    answers = %{
      multiselect: %{"Which agents to support" => ["muse"]},
      confirm: %{"Trust Muse to load skills and rules from agent workspaces?" => true}
    }

    assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))
    assert %{"agent" => agent} = written_config(target)
    assert agent["priority"] == ["muse"]
    assert agent["backend_configs"]["muse"]["trust_workspace"] == true
    assert agent["backend_configs"]["muse"]["approval_mode"] == "onRequest"
    assert "Trust Muse to load skills and rules from agent workspaces?" in confirm_prompts()
  end

  test "fresh Muse init keeps workspace trust disabled without affirmative choice", %{dir: dir, target: target} do
    answers = %{multiselect: %{"Which agents to support" => ["muse"]}}

    assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))
    assert written_config(target)["agent"]["backend_configs"]["muse"]["trust_workspace"] == false
    assert "Trust Muse to load skills and rules from agent workspaces?" in confirm_prompts()
  end

  test "fresh init calls a synthetic provider descriptor without provider branches", %{dir: dir, target: target} do
    descriptors =
      Map.put(CodingAgent.backends(), "synthetic", Map.put(Fake.entry(), :init, SyntheticInit))

    answers = %{
      multiselect: %{"Which agents to support" => ["synthetic"]},
      input: %{"Synthetic backend region" => "east"}
    }

    d = deps(self(), dir, target, %{backend_descriptors: descriptors})
    assert :ok = Init.run(%{force: false}, io(self(), answers), d)
    assert written_config(target)["agent"]["backend_configs"]["synthetic"]["region"] == "east"
    assert_received {:input_label, "Synthetic backend region"}
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
end
