defmodule Aiur.InitTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.Labels
  alias Aiur.Init
  alias Aiur.Workflow

  @example_file Path.expand("../../../.aiur/examples/config.example", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-init-test-#{System.unique_integer([:positive])}")
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
      confirm: fn label, default ->
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
        existing_config_path: fn t -> if File.regular?(t), do: t end,
        load_config: fn t ->
          with {:ok, loaded} <- Workflow.load(t), do: {:ok, loaded.config}
        end,
        migrate_layout: fn opts ->
          send(parent, {:migrate, opts})
          {:ok, %{moved: [opts.new_config]}}
        end,
        read_example: fn -> File.read!(@example_file) end,
        detect_repo: fn -> nil end,
        detect_toolchain: fn -> :none end,
        prewarm_build: fn url, cmd ->
          send(parent, {:prewarm_build, url, cmd})
          {:ok, "/base"}
        end,
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
        install_claude_app_server: fn -> :ok end,
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

  defp github_answers(overrides \\ %{}) do
    base = %{
      select: %{@location_label => "repo", "Issue tracker" => "github"},
      input: %{"GitHub repo (owner/name)" => "octo/repo"},
      multiselect: %{"Which agents to support" => ["claude"]}
    }

    Map.merge(base, overrides, fn _k, v1, v2 -> Map.merge(v1, v2) end)
  end

  describe "pre-warm opt-in" do
    test "detection + accept writes an enabled prewarm block with the command", %{dir: dir, target: target} do
      d =
        deps(self(), dir, target, %{
          detect_toolchain: fn ->
            {:ok, %{language: :elixir, build_root: "src", command: "mise exec -- mix compile"}}
          end
        })

      answers = github_answers(%{select: %{"Use this base build command?" => "use"}})

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      # init writes the command to the sibling .aiur/prewarm script and runs the
      # first warm-base build on opt-in
      assert_received {:prewarm_file, "mise exec -- mix compile"}
      assert_received {:prewarm_build, _url, "mise exec -- mix compile"}

      config = File.read!(target)
      assert config =~ "enabled: true"
      assert config =~ "base_build_file: prewarm"
      refute config =~ ~s(base_build: ")
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

    test "declining the opt-in leaves prewarm disabled", %{dir: dir, target: target} do
      d =
        deps(self(), dir, target, %{
          detect_toolchain: fn -> {:ok, %{language: :elixir, build_root: ".", command: "x"}} end
        })

      answers =
        github_answers(%{
          confirm: %{"Keep a pre-warmed copy of latest main so agents skip cloning + building?" => false}
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

      log = puts_log()
      assert Enum.any?(log, &(&1 =~ ~r/Saved selections/i))
      # The summary lists every saved selection, not just the first few.
      assert Enum.any?(log, &(&1 =~ ~r/repo: octo\/repo/))
      assert Enum.any?(log, &(&1 =~ ~r/routing: 1:/))
      assert Enum.any?(log, &(&1 =~ ~r/permission_mode: bypassPermissions/))
      assert Enum.any?(log, &(&1 =~ ~r/workspace_root:/))
      assert Enum.any?(log, &(&1 =~ ~r/polling_interval_seconds: 30/))
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

    test "resume migrates a legacy root config into .aiur/ when confirmed", %{dir: dir, target: target} do
      legacy = Path.join(dir, ".aiurconfig")
      File.write!(legacy, "tracker:\n  kind: memory\nagent:\n  kind: claude\n")

      answers = %{confirm: %{"Migrate them into .aiur/ now?" => true}}
      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))

      assert_received {:migrate, %{legacy_config: ^legacy, new_config: ^target, ignore: false}}
    end

    test "resume leaves the legacy layout when migration is declined", %{dir: dir, target: target} do
      legacy = Path.join(dir, ".aiurconfig")
      File.write!(legacy, "tracker:\n  kind: memory\n")

      answers = %{confirm: %{"Migrate them into .aiur/ now?" => false}}
      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))

      refute_received {:migrate, _opts}
    end

    test "resume migration passes ignore: true when the gitignore opt-in is accepted", %{dir: dir, target: target} do
      legacy = Path.join(dir, ".aiurconfig")
      File.write!(legacy, "tracker:\n  kind: memory\n")

      answers = %{
        confirm: %{"Migrate them into .aiur/ now?" => true, "Also add .aiur/ to .gitignore?" => true}
      }

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))

      assert_received {:migrate, %{ignore: true}}
    end

    test "resume verifies an existing enabled prewarm config", %{target: target} do
      File.write!(
        target,
        """
        tracker:
          kind: github
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

  describe "resume backfill of new config sections (#411)" do
    # A config written before the prewarm block existed.
    @legacy_yaml "tracker:\n  kind: github\n  github:\n    repo: octo/repo\nagent:\n  kind: claude\n"

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

    test "declining the offer leaves the existing config untouched", %{dir: dir, target: target} do
      File.write!(target, @legacy_yaml)
      before = File.read!(target)

      d =
        deps(self(), dir, target, %{
          detect_toolchain: fn -> {:ok, %{language: :elixir, build_root: ".", command: "x"}} end
        })

      answers = %{
        confirm: %{"Keep a pre-warmed copy of latest main so agents skip cloning + building?" => false}
      }

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      assert File.read!(target) == before
      refute_received {:append, ^target}
      refute_received {:prewarm_build, _url, _cmd}
    end
  end

  describe "migrate_layout/1" do
    setup do
      repo = Path.join(System.tmp_dir!(), "aiur-migrate-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: repo)
      {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: repo)
      {_, 0} = System.cmd("git", ["config", "user.name", "Tester"], cd: repo)
      on_exit(fn -> File.rm_rf!(repo) end)
      {:ok, repo: repo}
    end

    defp git_commit_all(repo) do
      {_, 0} = System.cmd("git", ["add", "."], cd: repo)
      {_, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: repo)
    end

    test "moves tracked files into .aiur/, rewrites pointers, removes legacy, preserves settings", %{repo: repo} do
      File.write!(Path.join(repo, ".aiurconfig"), "tracker:\n  kind: memory\nhooks_file: .aiurhooks\nprompt_file: AIUR.md\n")
      File.write!(Path.join(repo, ".aiurhooks"), "after_create: echo hi\n")
      File.write!(Path.join(repo, "AIUR.md"), "# prompt {{ issue.title }}\n")
      git_commit_all(repo)

      legacy = Path.join(repo, ".aiurconfig")
      new = Path.join([repo, ".aiur", "config"])

      assert {:ok, %{moved: _}} = Init.migrate_layout(%{legacy_config: legacy, new_config: new, ignore: false})

      assert File.regular?(new)
      assert File.regular?(Path.join([repo, ".aiur", "hooks"]))
      assert File.regular?(Path.join([repo, ".aiur", "prompt.md"]))
      refute File.regular?(legacy)
      refute File.regular?(Path.join(repo, ".aiurhooks"))
      refute File.regular?(Path.join(repo, "AIUR.md"))

      cfg = File.read!(new)
      assert cfg =~ "hooks_file: hooks"
      assert cfg =~ "prompt_file: prompt.md"
      # non-pointer settings preserved verbatim
      assert cfg =~ "kind: memory"
      assert File.read!(Path.join([repo, ".aiur", "hooks"])) =~ "echo hi"

      {tracked, 0} = System.cmd("git", ["ls-files"], cd: repo)
      assert tracked =~ ".aiur/config"
      refute tracked =~ ~r/^\.aiurconfig$/m
    end

    test "ignore: true appends .aiur/ to .gitignore and leaves new files untracked", %{repo: repo} do
      File.write!(Path.join(repo, ".aiurconfig"), "tracker:\n  kind: memory\n")
      git_commit_all(repo)

      legacy = Path.join(repo, ".aiurconfig")
      new = Path.join([repo, ".aiur", "config"])

      assert {:ok, _} = Init.migrate_layout(%{legacy_config: legacy, new_config: new, ignore: true})

      assert File.read!(Path.join(repo, ".gitignore")) =~ ".aiur/"
      refute File.regular?(legacy)
      {tracked, 0} = System.cmd("git", ["ls-files"], cd: repo)
      refute tracked =~ ".aiur/config"
    end

    test "untracked legacy files migrate via plain move", %{repo: repo} do
      File.write!(Path.join(repo, ".aiurconfig"), "tracker:\n  kind: memory\n")

      legacy = Path.join(repo, ".aiurconfig")
      new = Path.join([repo, ".aiur", "config"])

      assert {:ok, _} = Init.migrate_layout(%{legacy_config: legacy, new_config: new, ignore: false})
      assert File.regular?(new)
      refute File.regular?(legacy)
    end

    test "a missing legacy config returns an error and leaves nothing behind", %{repo: repo} do
      legacy = Path.join(repo, ".aiurconfig")
      new = Path.join([repo, ".aiur", "config"])

      assert {:error, _reason} = Init.migrate_layout(%{legacy_config: legacy, new_config: new, ignore: false})
      refute File.regular?(new)
    end

    test "a write failure leaves the legacy config intact (move-order safety)", %{repo: repo} do
      File.write!(Path.join(repo, ".aiurconfig"), "tracker:\n  kind: memory\n")
      legacy = Path.join(repo, ".aiurconfig")
      new = Path.join([repo, ".aiur", "config"])

      # A read+execute-only .aiur/ dir makes writing .aiur/config fail mid-migration.
      aiur_dir = Path.join(repo, ".aiur")
      File.mkdir_p!(aiur_dir)
      File.chmod!(aiur_dir, 0o500)

      assert {:error, _reason} = Init.migrate_layout(%{legacy_config: legacy, new_config: new, ignore: false})
      assert File.regular?(legacy)
      refute File.regular?(new)

      File.chmod!(aiur_dir, 0o755)
    end

    test "a pointer target outside the repo is never copied or deleted", %{repo: repo} do
      outside = Path.join(System.tmp_dir!(), "aiur-outside-#{System.unique_integer([:positive])}.md")
      File.write!(outside, "external prompt\n")
      on_exit(fn -> File.rm_rf!(outside) end)

      File.write!(Path.join(repo, ".aiurconfig"), "tracker:\n  kind: memory\nprompt_file: #{outside}\n")
      legacy = Path.join(repo, ".aiurconfig")
      new = Path.join([repo, ".aiur", "config"])

      assert {:ok, _} = Init.migrate_layout(%{legacy_config: legacy, new_config: new, ignore: false})

      # external file untouched; pointer left absolute (still resolves) and not rewritten
      assert File.regular?(outside)
      refute File.regular?(Path.join([repo, ".aiur", "prompt.md"]))
      assert File.read!(new) =~ "prompt_file: #{outside}"
    end

    test "a config with inline hooks (no hooks_file) migrates without a spurious pointer", %{repo: repo} do
      File.write!(Path.join(repo, ".aiurconfig"), "tracker:\n  kind: memory\nhooks:\n  after_create: echo hi\n")
      legacy = Path.join(repo, ".aiurconfig")
      new = Path.join([repo, ".aiur", "config"])

      assert {:ok, _} = Init.migrate_layout(%{legacy_config: legacy, new_config: new, ignore: false})
      cfg = File.read!(new)
      refute cfg =~ "hooks_file:"
      assert cfg =~ "after_create: echo hi"
      refute File.regular?(Path.join([repo, ".aiur", "hooks"]))
    end

    test "a custom hooks_file path migrates to .aiur/hooks and rewrites the pointer", %{repo: repo} do
      File.mkdir_p!(Path.join(repo, "scripts"))
      File.write!(Path.join([repo, "scripts", "wh"]), "after_create: echo hi\n")
      File.write!(Path.join(repo, ".aiurconfig"), "tracker:\n  kind: memory\nhooks_file: scripts/wh\n")
      legacy = Path.join(repo, ".aiurconfig")
      new = Path.join([repo, ".aiur", "config"])

      assert {:ok, _} = Init.migrate_layout(%{legacy_config: legacy, new_config: new, ignore: false})
      assert File.regular?(Path.join([repo, ".aiur", "hooks"]))
      assert File.read!(new) =~ "hooks_file: hooks"
    end

    test "a quoted prompt_file value containing a space is rewritten whole", %{repo: repo} do
      File.write!(Path.join(repo, "my prompt.md"), "# p\n")
      File.write!(Path.join(repo, ".aiurconfig"), ~s(tracker:\n  kind: memory\nprompt_file: "my prompt.md"\n))
      legacy = Path.join(repo, ".aiurconfig")
      new = Path.join([repo, ".aiur", "config"])

      assert {:ok, _} = Init.migrate_layout(%{legacy_config: legacy, new_config: new, ignore: false})
      cfg = File.read!(new)
      assert cfg =~ "prompt_file: prompt.md"
      refute cfg =~ "my prompt.md"
      assert File.regular?(Path.join([repo, ".aiur", "prompt.md"]))
    end

    test "ignore: true is idempotent — .aiur/ appears once in .gitignore", %{repo: repo} do
      File.write!(Path.join(repo, ".gitignore"), ".aiur/\n")
      File.write!(Path.join(repo, ".aiurconfig"), "tracker:\n  kind: memory\n")
      legacy = Path.join(repo, ".aiurconfig")
      new = Path.join([repo, ".aiur", "config"])

      assert {:ok, _} = Init.migrate_layout(%{legacy_config: legacy, new_config: new, ignore: true})

      occurrences =
        Path.join(repo, ".gitignore")
        |> File.read!()
        |> String.split("\n")
        |> Enum.count(&(String.trim(&1) == ".aiur/"))

      assert occurrences == 1
    end

    test "the migrated config loads via Workflow.load", %{repo: repo} do
      File.write!(Path.join(repo, ".aiurconfig"), "tracker:\n  kind: memory\nhooks_file: .aiurhooks\nprompt_file: AIUR.md\n")
      File.write!(Path.join(repo, ".aiurhooks"), "after_create: echo hi\n")
      File.write!(Path.join(repo, "AIUR.md"), "# prompt {{ issue.title }}\n")
      legacy = Path.join(repo, ".aiurconfig")
      new = Path.join([repo, ".aiur", "config"])

      assert {:ok, _} = Init.migrate_layout(%{legacy_config: legacy, new_config: new, ignore: false})
      assert {:ok, loaded} = Workflow.load(new)
      assert loaded.config["hooks"]["after_create"] == "echo hi"
      assert loaded.prompt =~ "{{ issue.title }}"
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
    end

    test "the global config omits the repo-specific prompt_file", %{dir: dir, target: target} do
      answers = github_answers(%{select: %{@location_label => "global"}})

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))
      assert written_config(target)["prompt_file"] == nil
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
               label == "Max agent duration in minutes" and hint == "Fallback for stuck agents: none = never auto-kill"
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
            "complexity:2 codex effort" => "high",
            "complexity:5 backend" => "claude",
            "complexity:5 claude model" => "sonnet"
          }
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps(self(), dir, target))

      routing = written_config(target)["agent"]["routing"]
      assert routing[1] == "claude:haiku"
      assert routing[2] == "codex::high"
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
      assert codex_efforts == ["default effort", "low", "medium", "high"]
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
      assert joined =~ "repo` scope"
      assert joined =~ "Only select repositories"
      assert joined =~ "Read and write"
      assert joined =~ "Issues"
      assert joined =~ "Contents"
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
      assert Enum.any?(log, &(&1 =~ ~r/Lifecycle agent tags: created\./))
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

      # Lifecycle (agent:rework missing) re-prompts its Enter gate; complexity
      # (complexity:5 missing) re-asks its confirm. Fully-present stages do not.
      assert Enum.any?(input_labels(), &(&1 =~ ~r/Press Enter to create/i))
      prompts = confirm_prompts()
      assert "Create the complexity labels?" in prompts
      refute "Create the model labels?" in prompts
      refute "Create the model:remote label?" in prompts

      assert Enum.any?(puts_log(), &(&1 =~ ~r/Model tags: created\./))
    end

    test "lifecycle labels are gated behind an explicit Enter", %{dir: dir, target: target} do
      deps = deps(self(), dir, target, %{github_token: fn -> "ghp_test" end})

      assert :ok = Init.run(%{force: false}, io(self(), github_answers()), deps)

      assert Enum.any?(input_labels(), &(&1 =~ ~r/Press Enter to create/i))
      assert Enum.any?(puts_log(), &(&1 =~ ~r/lifecycle ticket labels are required/i))
    end

    test "optional stages can be skipped without creating their labels", %{dir: dir, target: target} do
      deps = deps(self(), dir, target, %{github_token: fn -> "ghp_test" end})

      answers =
        github_answers(%{
          confirm: %{
            "Create the complexity labels?" => false,
            "Create the model labels?" => false,
            "Create the model:remote label?" => false
          }
        })

      assert :ok = Init.run(%{force: false}, io(self(), answers), deps)

      created = labels_created()
      assert created != []
      assert Enum.all?(created, &String.starts_with?(&1, "agent:"))
      refute Enum.any?(created, &String.starts_with?(&1, "complexity:"))
      refute Enum.any?(created, &String.starts_with?(&1, "model:"))
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
          install_claude_app_server: fn ->
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
          install_claude_app_server: fn ->
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
          install_claude_app_server: fn ->
            send(parent, {:install, :claude})
            :ok
          end
        })

      assert :ok = Init.run(%{force: false}, io(parent, answers), d)

      refute_received {:install, :claude}
    end

    test "a failed install prints a manual-install hint and init still completes", %{
      dir: dir,
      target: target
    } do
      parent = self()

      d =
        deps(parent, dir, target, %{
          check_agent_auth: fn
            "claude" -> @missing_claude
            _ -> :ok
          end,
          install_claude_app_server: fn -> {:error, "npm not found on PATH"} end
        })

      assert :ok = Init.run(%{force: false}, io(parent, github_answers()), d)

      assert Enum.any?(puts_log(), &(&1 =~ ~r/npm install -g aiur-claude/))
    end
  end
end
