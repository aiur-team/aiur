defmodule Aiur.Init.AlertsAndGenerationTest do
  use Aiur.InitCase

  @reuse_global_alerts_label "Found an existing alerts file at ~/.aiur/alerts — copy it into this repo's .aiur/alerts?"
  @location_label "Where will you store aiur settings for this project?"

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
      assert Enum.any?(log, &(&1 =~ ~r/polling_interval_seconds: 120/))
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

    test "declining the offer records the choice in existing config", %{dir: dir, target: target} do
      File.write!(target, @legacy_yaml)
      before = File.read!(target)

      d =
        deps(self(), dir, target, %{
          detect_toolchain: fn -> {:ok, %{language: :elixir, build_root: ".", command: "x"}} end
        })

      answers = %{
        confirm: %{"Keep a pre-warmed copy of the configured base branch so agents skip cloning + building?" => false}
      }

      assert :ok = Init.run(%{force: false}, io(self(), answers), d)

      assert File.read!(target) =~ "prewarm:\n  enabled: false"
      assert File.read!(target) != before
      joined = Enum.join(puts_log(), "\n")
      assert joined =~ "Saved declined warm-base pre-warm to"
      refute joined =~ "Added warm-base pre-warm to"
      refute_received {:append, ^target, _yaml}
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
end
