defmodule Aiur.AlertsConfigTest do
  use Aiur.TestSupport

  alias Aiur.Alerts

  describe "alerts file loading" do
    @tag :tmp_dir
    test "yields {} when the yaml file is unreadable or malformed", %{tmp_dir: tmp_dir} do
      # Point Alerts at a non-existent path; load_yaml falls back to %{}.
      original = Application.get_env(:aiur, :alerts_file_path)

      Application.put_env(
        :aiur,
        :alerts_file_path,
        Path.join(tmp_dir, "missing.yaml")
      )

      on_exit(fn ->
        if original do
          Application.put_env(:aiur, :alerts_file_path, original)
        else
          Application.delete_env(:aiur, :alerts_file_path)
        end
      end)

      assert Alerts.definitions() == %{}
    end

    @tag :tmp_dir
    test "returns an empty map when the yaml `alerts:` value isn't a map", %{tmp_dir: tmp_dir} do
      # Triggers the `normalize_definitions(_definitions), do: %{}`
      # fallback clause via a yaml file that has a non-map `alerts:`.
      yaml_path = Path.join(tmp_dir, "alerts.yaml")
      File.write!(yaml_path, "alerts: not_a_map\n")

      original = Application.get_env(:aiur, :alerts_file_path)
      Application.put_env(:aiur, :alerts_file_path, yaml_path)

      on_exit(fn ->
        if original do
          Application.put_env(:aiur, :alerts_file_path, original)
        else
          Application.delete_env(:aiur, :alerts_file_path)
        end
      end)

      assert Alerts.definitions() == %{}
    end

    @tag :tmp_dir
    test "drops sound values that are neither nil, a string, nor a list", %{tmp_dir: tmp_dir} do
      # `normalize_sounds/1`'s fallback returns `[]` for unexpected
      # shapes (integer, map, etc).
      yaml_path = Path.join(tmp_dir, "alerts.yaml")

      File.write!(yaml_path, """
      alerts:
        bad_sound_shape:
          message: "Hi"
          sound: 42
      """)

      original = Application.get_env(:aiur, :alerts_file_path)
      Application.put_env(:aiur, :alerts_file_path, yaml_path)

      on_exit(fn ->
        if original do
          Application.put_env(:aiur, :alerts_file_path, original)
        else
          Application.delete_env(:aiur, :alerts_file_path)
        end
      end)

      assert %{"bad_sound_shape" => %{sound: []}} = Alerts.definitions()
    end

    @tag :tmp_dir
    test "skips entries whose value is not a map and entries with a blank message", %{tmp_dir: tmp_dir} do
      yaml_path = Path.join(tmp_dir, "alerts.yaml")

      File.write!(yaml_path, """
      alerts:
        good:
          message: "Hello"
          sound: "~/sounds/one.wav"
        also_good:
          message: "List sound"
          sound:
            - "/tmp/a.wav"
            - "/tmp/b.wav"
        not_a_map: "just a string"
        blank_message:
          message: ""
      """)

      original = Application.get_env(:aiur, :alerts_file_path)
      Application.put_env(:aiur, :alerts_file_path, yaml_path)

      on_exit(fn ->
        if original do
          Application.put_env(:aiur, :alerts_file_path, original)
        else
          Application.delete_env(:aiur, :alerts_file_path)
        end
      end)

      definitions = Alerts.definitions()

      assert Map.has_key?(definitions, "good")
      assert Map.has_key?(definitions, "also_good")
      refute Map.has_key?(definitions, "not_a_map")
      refute Map.has_key?(definitions, "blank_message")

      # Sound paths are stored verbatim at load time; `~/` expansion
      # happens lazily at pick time in `expand_sound_path/1`.
      assert ["~/sounds/one.wav"] == definitions["good"].sound
      assert ["/tmp/a.wav", "/tmp/b.wav"] == definitions["also_good"].sound
    end
  end

  describe "legacy .aiur/alerts.yaml fallback removal" do
    test "ignores a legacy .aiur/alerts.yaml — canonical file wins, yaml never loaded, warns when only yaml remains" do
      # The default path (no :alerts_file_path override, no config alerts_file)
      # resolves to `<config-dir>/alerts`; the sibling `.aiur/alerts.yaml` is the
      # legacy file that must never be parsed. Both live next to the per-test
      # config that TestSupport's setup already wrote.
      config_dir = Path.dirname(Workflow.workflow_file_path())
      canonical = Path.join(config_dir, "alerts")
      legacy = Path.join(config_dir, "alerts.yaml")

      # A marker entry that must NEVER surface if the yaml were loaded.
      File.write!(legacy, """
      alerts:
        "legacy.only.topic":
          message: "LEGACY YAML LOADED"
      """)

      # Canonical extensionless file present with distinct contents → it wins,
      # the yaml is ignored, and no deprecation warning fires.
      File.write!(canonical, """
      alerts:
        "canonical.topic":
          message: "From canonical alerts"
      """)

      log =
        capture_log(fn ->
          defs = Alerts.definitions()
          assert defs["canonical.topic"].message == "From canonical alerts"
          refute Map.has_key?(defs, "legacy.only.topic")
        end)

      refute log =~ "fallback was removed"

      # Remove the canonical file → only the legacy yaml remains. Mappings must
      # resolve to an empty map (the yaml is still never parsed — no marker
      # entry leaks) and the one-time deprecation warning must fire, naming the
      # rename the operator needs to make.
      File.rm!(canonical)

      log =
        capture_log(fn ->
          assert Alerts.definitions() == %{}
        end)

      assert log =~ "fallback was removed"
      assert log =~ "Rename #{legacy} to #{canonical}"
    end

    test "with no alerts file at all the default path resolves to an empty map and emission is a silent no-op" do
      # No canonical `.aiur/alerts`, no legacy `.aiur/alerts.yaml`, no override:
      # the default-path branch must resolve cleanly to `%{}` without crashing,
      # emitting plays no mapped sound, and no deprecation warning fires.
      config_dir = Path.dirname(Workflow.workflow_file_path())
      File.rm_rf!(Path.join(config_dir, "alerts"))
      File.rm_rf!(Path.join(config_dir, "alerts.yaml"))

      topic = "task.no-alerts-file.#{System.unique_integer([:positive])}"
      probe = fn sound -> send(self(), {:played, sound}) end

      log =
        capture_log(fn ->
          assert Alerts.definitions() == %{}
          assert is_nil(Alerts.definition_for_topic(topic))
          assert :ok = Alerts.emit_custom(topic, "No mapping present", player: probe)
        end)

      refute_receive {:played, _sound}, 100
      refute log =~ "fallback was removed"
    end
  end

  describe "config-driven alert settings" do
    setup do
      workspace_root =
        Aiur.TestSupport.tmp_root!("aiur-alert-cfg")

      File.mkdir_p!(Path.join(workspace_root, "MT-CFG"))
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace_root) end)

      %{workspace_root: workspace_root}
    end

    test "enabled: false gates playback even with a player override", %{workspace_root: root} do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        alerts_enabled: false
      )

      probe = fn sound -> send(self(), {:played, sound}) end

      assert :ok =
               Alerts.emit_system("ticket.MT-CFG.agent.paused", issue: "MT-CFG", player: probe)

      refute_receive {:played, _sound}, 100
    end

    test "OS-default mode resolves a <category> override file from sound_dir", %{
      workspace_root: root
    } do
      sound_dir = Path.join(root, "sounds")
      File.mkdir_p!(sound_dir)
      stuck_file = Path.join(sound_dir, "stuck.wav")
      File.write!(stuck_file, "")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        alerts_enabled: true,
        alerts_use_os_default_sounds: true,
        alerts_sound_dir: sound_dir
      )

      probe = fn sound -> send(self(), {:played, sound}) end

      assert :ok =
               Alerts.emit_system("ticket.MT-CFG.agent.paused", issue: "MT-CFG", player: probe)

      assert_receive {:played, ^stuck_file}, 1000
    end

    test "mapping mode loads the config alerts_file and joins bare sound names to sound_dir", %{
      workspace_root: root
    } do
      # Exercises two new seams at once: (1) alerts_path precedence — with no
      # :alerts_file_path app-env override set, the config `alerts_file` is used
      # instead of the bundled alerts file; (2) resolve_sound_path joins a bare
      # filename from the mapping onto `sound_dir`.
      sound_dir = Path.join(root, "clips")
      File.mkdir_p!(sound_dir)

      custom_yaml = Path.join(root, "custom-alerts.yaml")

      File.write!(custom_yaml, """
      alerts:
        "ticket.*.agent.paused":
          message: Custom paused
          sound:
            - "custom-stuck.wav"
      """)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        alerts_enabled: true,
        alerts_use_os_default_sounds: false,
        alerts_sound_dir: sound_dir,
        alerts_file: custom_yaml
      )

      probe = fn sound -> send(self(), {:played, sound}) end
      expected = Path.join(sound_dir, "custom-stuck.wav")

      assert :ok =
               Alerts.emit_system("ticket.MT-CFG.agent.paused", issue: "MT-CFG", player: probe)

      assert_receive {:played, ^expected}, 1000
    end

    test "OS-default mode falls back to the host OS sound for the category", %{
      workspace_root: root
    } do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        alerts_enabled: true,
        alerts_use_os_default_sounds: true
      )

      probe = fn sound -> send(self(), {:played, sound}) end

      assert :ok =
               Alerts.emit_system("ticket.MT-CFG.agent.paused", issue: "MT-CFG", player: probe)

      # Deterministic across hosts: assert the real OS sound when this host ships
      # it, otherwise assert the no-op (nothing played) safety path.
      case Enum.find(Alerts.os_sound_candidates(:stuck, :os.type()), &File.exists?/1) do
        nil -> refute_receive {:played, _sound}, 100
        path -> assert_receive {:played, ^path}, 1000
      end
    end

    test "a missing config alerts_file falls back to the bundled mapping", %{workspace_root: root} do
      # A typo'd / non-existent custom alerts_file must not silently kill all
      # alert sounds — alerts_path falls back to the bundled alerts file, so a
      # real bundled topic still resolves its sound.
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        alerts_enabled: true,
        alerts_file: Path.join(root, "does-not-exist.yaml")
      )

      probe = fn sound -> send(self(), {:played, sound}) end

      assert :ok =
               Alerts.emit_system("ticket.MT-CFG.issue.state.changed", issue: "MT-CFG", player: probe)

      expected = Path.join(System.user_home!(), "alerts/advisor-upgrade-complete.wav")
      assert_receive {:played, ^expected}, 1000
    end
  end
end
