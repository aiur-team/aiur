defmodule Aiur.ProviderMeterProbeWorkspaceTest do
  use Aiur.TestSupport

  alias Aiur.ProviderMeterProbe

  defmodule RecordingAgent do
    def start_session(workspace, _opts) do
      send(self(), {:probe_workspace, workspace})
      {:error, :test_session_finished}
    end
  end

  @tag home_expansion_child: true
  @tag timeout: :infinity
  test "provider probe expands relative and tilde roots from an isolated HOME" do
    if System.get_env("AIUR_HOME_EXPANSION_CHILD") != "1" do
      home = Aiur.TestSupport.tmp_root!("probe-home")
      File.mkdir_p!(home)

      {output, status} =
        System.cmd(
          System.find_executable("mix"),
          ["test", __ENV__.file, "--only", "home_expansion_child:true"],
          env: [{"HOME", home}, {"AIUR_HOME_EXPANSION_CHILD", "1"}],
          stderr_to_stdout: true
        )

      Aiur.TestCleanup.rm_rf!(home)
      assert status == 0, output
    else
      for representation <- [:relative, :home_relative] do
        run_probe_workspace_case!(representation)
      end
    end
  end

  defp run_probe_workspace_case!(representation) do
    home = System.user_home!()
    File.mkdir_p!(home)

    root =
      case representation do
        :relative -> Path.join(File.cwd!(), ".verification/probe-#{System.unique_integer([:positive])}")
        :home_relative -> Path.join([home, ".cache", Path.basename(Aiur.TestSupport.tmp_root!("probe-expanded-root"))])
      end

    File.mkdir_p!(root)

    configured_root =
      case representation do
        :relative -> Path.relative_to(root, File.cwd!())
        :home_relative -> String.replace_prefix(root, home, "~")
      end

    refute Path.type(configured_root) == :absolute
    literal_root = Path.join(File.cwd!(), configured_root)

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(literal_root)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    previous_home = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      if previous_home, do: System.put_env("HOME", previous_home), else: System.delete_env("HOME")
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: configured_root)

    ProviderMeterProbe.observe(:codex, probe_agent: RecordingAgent, backend_configs: %{})

    assert_received {:probe_workspace, workspace}

    assert workspace == Aiur.Workspace.workspace_path_under(root, "usage-probe") |> Path.expand()

    assert File.dir?(workspace)
  end
end
