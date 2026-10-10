defmodule Aiur.Init.InstallAndGlobalTest do
  use Aiur.InitCase

  @location_label "Where will you store aiur settings for this project?"

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
          claude_registry_version: fn -> {:ok, "1.1.0"} end,
          install_claude_app_server: fn _spec ->
            send(parent, {:install, :claude})
            Agent.update(present, fn _ -> true end)
            :ok
          end
        })

      assert :ok = Init.run(%{force: false}, io(parent, github_answers()), d)

      assert_received {:install, :claude}
      refute Enum.any?(puts_log(), &(&1 =~ ~r/not found on PATH/))
    end

    test "skips the install when aiur-claude already resolves", %{dir: dir, target: target} do
      parent = self()

      d =
        deps(parent, dir, target, %{
          check_agent_auth: fn _kind -> :ok end,
          install_claude_app_server: fn _spec ->
            send(parent, {:install, :claude})
            :ok
          end
        })

      assert :ok = Init.run(%{force: false}, io(parent, github_answers()), d)

      refute_received {:install, :claude}
    end

    test "never installs when claude is not selected", %{dir: dir, target: target} do
      parent = self()
      answers = github_answers(%{multiselect: %{"Which agents to support" => ["codex"]}})

      d =
        deps(parent, dir, target, %{
          check_agent_auth: fn _kind -> :ok end,
          install_claude_app_server: fn _spec ->
            send(parent, {:install, :claude})
            :ok
          end
        })

      assert :ok = Init.run(%{force: false}, io(parent, answers), d)

      refute_received {:install, :claude}
    end

    test "an aiur-claude still below the minimum after install stops init", %{
      dir: dir,
      target: target
    } do
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
      assert File.read!(target) =~ "tracker:"
    end

    test "a current aiur-claude prints no version warning", %{dir: dir, target: target} do
      parent = self()
      d = deps(parent, dir, target, %{claude_version: fn -> {:ok, "1.1.0"} end})

      assert :ok = Init.run(%{force: false}, io(parent, github_answers()), d)

      refute Enum.any?(puts_log(), &(&1 =~ ~r/aiur-claude/ and &1 =~ ~r/older than/))
    end

    test "a satisfying installed adapter completes without reinstalling", %{dir: dir, target: target} do
      parent = self()
      d = deps(parent, dir, target, %{claude_version: fn -> {:ok, "1.1.0"} end})

      assert :ok = Init.run(%{force: false}, io(parent, github_answers()), d)

      refute_received {:install, _spec}
    end
  end

  describe "global config with no repo-local config" do
    @scope_label_prefix "Use the global config at "
    @repo_option "repo (./.aiur/)"
    @global_option "global (~/.aiur/)"

    defp global_config_yaml(repo) do
      github = if repo, do: "  github:\n    repo: #{repo}\n", else: ""

      """
      tracker:
        kind: github
        base_branch: main
      #{github}agent:
        kind: claude
      prewarm:
        enabled: false
      """
    end

    # Per-location config targets: the repo-local target is `target` (absent
    # unless a test writes it) and the global one lives under a fake home dir
    # that already holds a config tracking `global_repo`.
    defp scoped_deps(parent, dir, target, global_repo, overrides \\ %{}) do
      global_target = Path.join([dir, "home", ".aiur", "config"])
      File.mkdir_p!(Path.dirname(global_target))
      File.write!(global_target, global_config_yaml(global_repo))

      d =
        deps(
          parent,
          dir,
          target,
          Map.merge(
            %{
              config_target: fn
                :global -> global_target
                _location -> target
              end,
              legacy_config_target: fn
                :global -> Path.join([dir, "home", ".aiurconfig"])
                _location -> Path.join(dir, ".aiurconfig")
              end,
              detect_repo: fn -> "octo/repo" end
            },
            overrides
          )
        )

      {d, global_target}
    end

    defp scope_prompt do
      receive do
        {:select_prompt, @scope_label_prefix <> _rest = label, opts, default} -> {label, opts, default}
      after
        0 -> nil
      end
    end

    defp asked_location? do
      Enum.any?(input_labels() ++ select_prompt_labels(), &(&1 == @location_label))
    end

    defp select_prompt_labels(acc \\ []) do
      receive do
        {:select_prompt, label, _opts, _default} -> select_prompt_labels([label | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "a differing remote prompts with repo-local as the default and creates the repo-local config", %{dir: dir, target: target} do
      {d, global_target} = scoped_deps(self(), dir, target, "octo/other")
      global_before = File.read!(global_target)

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), d)

      assert {label, [@repo_option, @global_option], @repo_option} = scope_prompt()
      assert label =~ global_target
      assert label =~ "repo-local .aiur/config for octo/repo"
      refute asked_location?()

      assert_received {:write, ^target}
      assert get_in(written_config(target), ["tracker", "github", "repo"]) == "octo/repo"
      assert File.read!(global_target) == global_before
      refute Enum.any?(puts_log(), &(&1 =~ "resuming setup"))
    end

    test "a matching remote prompts with global as the default and resumes the global config", %{dir: dir, target: target} do
      {d, global_target} = scoped_deps(self(), dir, target, "octo/repo")

      assert :ok = Init.run(%{force: false}, io(self()), d)

      assert {_label, _opts, @global_option} = scope_prompt()
      refute asked_location?()
      refute_received {:write, _path}
      refute File.exists?(target)

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ "Found an existing config at #{global_target}; resuming setup."))
      assert Enum.any?(log, &(&1 =~ ~r/Saved selections/i))
    end

    test "the remote match is case-insensitive", %{dir: dir, target: target} do
      {d, _global_target} = scoped_deps(self(), dir, target, "Octo/Repo")

      assert :ok = Init.run(%{force: false}, io(self()), d)

      assert {_label, _opts, @global_option} = scope_prompt()
    end

    test "choosing global on a differing remote resumes the global config", %{dir: dir, target: target} do
      {d, global_target} = scoped_deps(self(), dir, target, "octo/other")
      answers = %{select: %{"#{@scope_label_prefix}#{global_target}, or create a repo-local .aiur/config for octo/repo?" => "global"}}

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      refute_received {:write, _path}
      assert Enum.any?(puts_log(), &(&1 =~ "resuming setup"))
    end

    test "choosing repo-local on a matching remote runs a fresh repo-local setup", %{dir: dir, target: target} do
      {d, global_target} = scoped_deps(self(), dir, target, "octo/repo")
      global_before = File.read!(global_target)

      answers =
        github_answers(%{
          select: %{"#{@scope_label_prefix}#{global_target}, or create a repo-local .aiur/config for octo/repo?" => "repo"}
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      assert_received {:write, ^target}
      assert File.read!(global_target) == global_before
      refute asked_location?()
    end

    test "a global config that pins no repo defaults to global", %{dir: dir, target: target} do
      {d, _global_target} = scoped_deps(self(), dir, target, nil)

      assert :ok = Init.run(%{force: false}, io(self()), d)

      assert {_label, _opts, @global_option} = scope_prompt()
      assert Enum.any?(puts_log(), &(&1 =~ ~r/Saved selections/i))
    end

    test "a directory with no detectable remote defaults to global", %{dir: dir, target: target} do
      {d, _global_target} = scoped_deps(self(), dir, target, "octo/other", %{detect_repo: fn -> nil end})

      assert :ok = Init.run(%{force: false}, io(self()), d)

      assert {label, _opts, @global_option} = scope_prompt()
      assert label =~ "repo-local .aiur/config for this repository?"
    end

    # Regression guard for pre-existing behavior: a repo-local config must keep
    # winning the probe, so the new scope prompt never fires here.
    test "an existing repo-local config resumes without the scope prompt", %{dir: dir, target: target} do
      {d, _global_target} = scoped_deps(self(), dir, target, "octo/other")
      File.write!(target, global_config_yaml("octo/repo"))

      assert :ok = Init.run(%{force: false}, io(self()), d)

      assert scope_prompt() == nil
      assert Enum.any?(puts_log(), &(&1 =~ "Found an existing config at #{target}; resuming setup."))
    end

    # Regression guard for pre-existing behavior: --force still asks the plain
    # location question and writes only the chosen target.
    test "--force skips the scope prompt and scopes the fresh setup to the chosen location", %{dir: dir, target: target} do
      {d, global_target} = scoped_deps(self(), dir, target, "octo/other")
      global_before = File.read!(global_target)

      assert :ok = Init.run(%{force: true}, io(self(), github_answers()), d)

      assert scope_prompt() == nil
      assert_received {:write, ^target}
      assert File.read!(global_target) == global_before
    end

    test "an unreadable global config defaults to global and keeps the --force hint", %{dir: dir, target: target} do
      {d, global_target} = scoped_deps(self(), dir, target, "octo/other")
      File.write!(global_target, "- not\n- a\n- map\n")

      assert {:error, message} = Init.run(%{force: false}, io(self()), d)

      assert {_label, _opts, @global_option} = scope_prompt()
      assert message =~ "Couldn't read the existing config at #{global_target}"
      assert message =~ "--force"
      refute_received {:write, _path}
    end

    test "a legacy global config still offers a repo-local setup", %{dir: dir, target: target} do
      {d, _global_target} = scoped_deps(self(), dir, target, "octo/other")
      legacy = Path.join([dir, "home", ".aiurconfig"])
      File.write!(legacy, global_config_yaml("octo/other"))
      # The legacy hit is probed after the canonical global path; drop the
      # canonical file so the legacy one is what the wizard finds.
      File.rm!(Path.join([dir, "home", ".aiur", "config"]))

      assert {:error, message} = Init.run(%{force: false}, io(self()), d)
      assert {_label, _opts, @global_option} = scope_prompt()
      assert message =~ "#{legacy} is no longer supported"

      answers = github_answers(%{select: %{"#{@scope_label_prefix}#{legacy}, or create a repo-local .aiur/config for octo/repo?" => "repo"}})
      assert :ok = Init.run(%{force: false}, io(self(), answers), d)
      assert_received {:write, ^target}
    end
  end
end
