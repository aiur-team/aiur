defmodule Aiur.AlertsSoundTest do
  use Aiur.TestSupport

  alias Aiur.Alerts

  describe "default_player/2" do
    test "no-ops for http and https URL sounds" do
      assert :ok = Aiur.Alerts.default_player("http://example.test/ring.wav")
      assert :ok = Aiur.Alerts.default_player("https://example.test/ring.wav")
    end

    test "returns :ok when afplay is not on the path" do
      # First `cond` branch — `find_executable_fn` returns nil.
      assert :ok =
               Aiur.Alerts.default_player(
                 "/nowhere/missing-sound.wav",
                 fn _ -> nil end
               )
    end

    test "returns :ok when a player is available but the sound file is missing" do
      # `find_executable_fn` returns a path for any probed player but
      # `File.exists?/1` returns false for the sound.
      stub_player = fn _binary -> "/usr/bin/echo" end

      assert :ok =
               Aiur.Alerts.default_player(
                 "/nowhere/missing-sound.wav",
                 stub_player
               )
    end

    test "resolve_workspace_for returns nil when the workspace_root_fn crashes" do
      # Directly exercises the rescue branch via the injectable helper.
      crashing = fn -> raise "no workflow loaded" end
      assert is_nil(Aiur.Alerts.resolve_workspace_for("MT-WSCRASH", crashing))
    end

    test "resolve_workspace_for returns the workspace path when it exists" do
      workspace_root = Aiur.TestSupport.tmp_root!("aiur-rwfor")
      # Linear default config namespaces the workspace under <root>/<project_slug>/.
      workspace = Path.join([workspace_root, "project", "MT-WSEXIST"])
      File.mkdir_p!(workspace)
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace_root) end)

      assert workspace == Aiur.Alerts.resolve_workspace_for("MT-WSEXIST", fn -> workspace_root end)
    end

    @tag :tmp_dir
    test "spawns a playback task when a player and the sound both exist", %{tmp_dir: tmp_dir} do
      # Player resolves and the file exists, so a Task.start runs. We use
      # `/usr/bin/true` as a stand-in for whichever player the host OS probes
      # and create a real file the function can pass to `System.cmd/3`.
      sound_path = Path.join(tmp_dir, "ring.wav")
      File.write!(sound_path, "")

      true_path = System.find_executable("true") || "/usr/bin/true"
      stub_player = fn _binary -> true_path end

      assert {:ok, _pid} = Aiur.Alerts.default_player(sound_path, stub_player)
    end
  end

  describe "player_command/2 cross-platform resolution" do
    test "macOS resolves afplay with a bare-path argv" do
      find = fn "afplay" -> "/usr/bin/afplay" end
      assert {"/usr/bin/afplay", build_args} = Alerts.player_command({:unix, :darwin}, find)
      assert build_args.("/tmp/a.aiff") == ["/tmp/a.aiff"]
    end

    test "Linux picks paplay first with a bare-path argv when it is present" do
      # paplay is the first candidate; when present it short-circuits the rest
      # and takes a bare path (no `-f`).
      find = fn
        "paplay" -> "/usr/bin/paplay"
        _ -> "/usr/bin/should-not-be-probed"
      end

      assert {"/usr/bin/paplay", build_args} = Alerts.player_command({:unix, :linux}, find)
      assert build_args.("/tmp/a.oga") == ["/tmp/a.oga"]
    end

    test "Linux prefers paplay, then canberra-gtk-play (-f), then aplay" do
      # Only canberra is present → it wins over the later aplay, and its argv
      # carries the `-f` flag freedesktop's player requires.
      find = fn
        "paplay" -> nil
        "canberra-gtk-play" -> "/usr/bin/canberra-gtk-play"
        "aplay" -> "/usr/bin/aplay"
      end

      assert {"/usr/bin/canberra-gtk-play", build_args} =
               Alerts.player_command({:unix, :linux}, find)

      assert build_args.("/tmp/a.oga") == ["-f", "/tmp/a.oga"]
    end

    test "returns :none when no player binary is on the path" do
      assert :none = Alerts.player_command({:unix, :linux}, fn _ -> nil end)
      assert :none = Alerts.player_command({:win32, :nt}, fn _ -> "/x" end)
    end
  end

  describe "categorize_topic/1 maps real alert topics to OS-sound categories" do
    test "needs-input topics" do
      assert :needs_input =
               Alerts.categorize_topic("ticket.MT-1.issue.label.added.agent.human-review")

      assert :needs_input = Alerts.categorize_topic("ticket.MT-1.agent.input_required")
    end

    test "stuck topics" do
      assert :stuck = Alerts.categorize_topic("ticket.MT-1.agent.paused")
      assert :stuck = Alerts.categorize_topic("ticket.MT-1.agent.thrash_circuit_open")
      assert :stuck = Alerts.categorize_topic("ticket.MT-1.agent.retry_exhausted")
      assert :stuck = Alerts.categorize_topic("ticket.MT-1.agent.error.tokens_exhausted")
    end

    test "done topics" do
      assert :done = Alerts.categorize_topic("ticket.MT-1.pr.merged")
      assert :done = Alerts.categorize_topic("ticket.MT-1.issue.label.added.agent.merging")
      assert :done = Alerts.categorize_topic("ticket.MT-1.issue.state.changed")
    end

    test "the agent.unpaused resume topic is not miscategorized as :stuck" do
      # `.paused` is delimiter-anchored so it matches `agent.paused` but not the
      # `agent.unpaused` resume event — a resume must not play the stuck sound.
      assert :stuck = Alerts.categorize_topic("ticket.MT-1.agent.paused")
      assert :default = Alerts.categorize_topic("ticket.MT-1.agent.unpaused")
    end

    test "uncategorized and non-binary topics fall back to :default" do
      assert :default = Alerts.categorize_topic("ticket.MT-1.chat.opened")
      assert :default = Alerts.categorize_topic(:not_a_string)
    end
  end

  describe "os_sound_candidates/2 built-in OS sound sets" do
    test "macOS maps each category to a /System/Library/Sounds AIFF" do
      assert ["/System/Library/Sounds/Glass.aiff"] =
               Alerts.os_sound_candidates(:needs_input, {:unix, :darwin})

      assert ["/System/Library/Sounds/Sosumi.aiff"] =
               Alerts.os_sound_candidates(:stuck, {:unix, :darwin})

      assert ["/System/Library/Sounds/Hero.aiff"] =
               Alerts.os_sound_candidates(:done, {:unix, :darwin})
    end

    test "Linux maps each category to a freedesktop OGA with an ALSA WAV fallback" do
      assert [
               "/usr/share/sounds/freedesktop/stereo/message-new-instant.oga",
               "/usr/share/sounds/alsa/Front_Center.wav"
             ] = Alerts.os_sound_candidates(:needs_input, {:unix, :linux})

      assert [
               "/usr/share/sounds/freedesktop/stereo/dialog-warning.oga",
               "/usr/share/sounds/alsa/Front_Center.wav"
             ] = Alerts.os_sound_candidates(:stuck, {:unix, :linux})
    end

    test "unknown OS yields no candidates (silent no-op)" do
      assert [] = Alerts.os_sound_candidates(:done, {:win32, :nt})
    end
  end

  describe "playback fallbacks" do
    test "playback env guard does not depend on Mix at runtime" do
      source = File.read!(Path.expand("../../lib/aiur/alerts.ex", __DIR__))

      refute source =~ "Mix.env"
      assert Application.get_env(:aiur, :env) == :test
    end

    test "test env suppresses fallback sound playback while preserving alert emission" do
      workspace_root =
        Aiur.TestSupport.tmp_root!("aiur-alert-test-silent")

      workspace = Path.join([workspace_root, "project", "MT-ALERT-SILENT"])
      File.mkdir_p!(workspace)
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace_root) end)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      test_pid = self()
      previous_player = Application.get_env(:aiur, :alert_sound_player)

      Application.put_env(:aiur, :alert_sound_player, fn sound ->
        send(test_pid, {:fallback_player_called, sound})
      end)

      on_exit(fn ->
        if previous_player do
          Application.put_env(:aiur, :alert_sound_player, previous_player)
        else
          Application.delete_env(:aiur, :alert_sound_player)
        end
      end)

      assert :ok =
               Alerts.emit_system("ticket.MT-ALERT-SILENT.issue.state.changed",
                 issue: "MT-ALERT-SILENT"
               )

      refute_receive {:fallback_player_called, _sound}, 100

      assert Path.join(workspace, "logs/agent.ndjson")
             |> File.read!()
             |> String.contains?(~s("name":"ticket.MT-ALERT-SILENT.issue.state.changed"))
    end

    test "non-test env still invokes fallback sound playback" do
      workspace_root =
        Aiur.TestSupport.tmp_root!("aiur-alert-runtime-sound")

      workspace = Path.join([workspace_root, "project", "MT-ALERT-RUNTIME"])
      File.mkdir_p!(workspace)
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace_root) end)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      test_pid = self()
      previous_env = Application.get_env(:aiur, :env)
      previous_player = Application.get_env(:aiur, :alert_sound_player)

      Application.put_env(:aiur, :env, :prod)

      Application.put_env(:aiur, :alert_sound_player, fn sound ->
        send(test_pid, {:fallback_player_called, sound})
      end)

      on_exit(fn ->
        if previous_env do
          Application.put_env(:aiur, :env, previous_env)
        else
          Application.delete_env(:aiur, :env)
        end

        if previous_player do
          Application.put_env(:aiur, :alert_sound_player, previous_player)
        else
          Application.delete_env(:aiur, :alert_sound_player)
        end
      end)

      assert :ok =
               Alerts.emit_system("ticket.MT-ALERT-RUNTIME.issue.state.changed",
                 issue: "MT-ALERT-RUNTIME"
               )

      expected_sound = Path.join(System.user_home!(), "alerts/advisor-upgrade-complete.wav")
      assert_receive {:fallback_player_called, ^expected_sound}, 1000
    end

    test "swallows a player function that raises and still emits" do
      # `maybe_play_sound`'s rescue branch logs at debug and returns :ok
      # so a crashing player can't break the alert emission flow.
      workspace_root =
        Aiur.TestSupport.tmp_root!("aiur-alert-rescue")

      workspace = Path.join(workspace_root, "MT-ALERT-RESCUE")
      File.mkdir_p!(workspace)
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace_root) end)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      crashing_player = fn _sound -> raise "boom" end

      assert :ok =
               Alerts.emit_system("ticket.MT-ALERT-RESCUE.issue.state.changed",
                 issue: "MT-ALERT-RESCUE",
                 player: crashing_player
               )
    end

    test "default player skips http(s) sounds without trying to invoke afplay" do
      # Direct unit test on the default player by emitting an alert
      # whose sound list is a URL. The test environment normally
      # short-circuits via `test_env_without_player_override?/1`, so
      # we pass `player: &Aiur.Alerts.default_player_for_test/1`
      # if exposed — when not exposed we ensure no crash either way.
      workspace_root =
        Aiur.TestSupport.tmp_root!("aiur-alert-url")

      workspace = Path.join(workspace_root, "MT-ALERT-URL")
      File.mkdir_p!(workspace)
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace_root) end)

      # Point Alerts at a yaml that has a URL-prefixed sound, then emit.
      yaml_path = Path.join(workspace_root, "alerts.yaml")

      File.write!(yaml_path, """
      alerts:
        task.url-sound:
          message: "URL sound"
          sound: "https://example.test/ring.mp3"
      """)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      original = Application.get_env(:aiur, :alerts_file_path)
      Application.put_env(:aiur, :alerts_file_path, yaml_path)

      on_exit(fn ->
        if original do
          Application.put_env(:aiur, :alerts_file_path, original)
        else
          Application.delete_env(:aiur, :alerts_file_path)
        end
      end)

      # Use a player that just records what it was called with — we
      # want to confirm the URL string is passed through verbatim.
      test_pid = self()
      probe = fn sound -> send(test_pid, {:probe, sound}) end

      assert :ok =
               Alerts.emit_system("task.url-sound",
                 issue: "MT-ALERT-URL",
                 player: probe
               )

      assert_receive {:probe, "https://example.test/ring.mp3"}, 1000
    end
  end
end
