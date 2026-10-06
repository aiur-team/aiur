defmodule Aiur.ProviderMeterProbeWorkspaceTest do
  use Aiur.TestSupport

  alias Aiur.ProviderMeterProbe

  defmodule RecordingAgent do
    def start_session(workspace, _opts) do
      send(self(), {:probe_workspace, workspace})
      {:error, :test_session_finished}
    end
  end

  for representation <- [:relative, :home_relative] do
    test "provider probe creates and opens the same absolute directory for #{representation} roots" do
      root =
        case unquote(representation) do
          :relative -> Path.join(File.cwd!(), ".verification/probe-#{System.unique_integer([:positive])}")
          :home_relative -> Path.join([System.user_home!(), ".cache", Path.basename(Aiur.TestSupport.tmp_root!("probe-expanded-root"))])
        end

      configured_root =
        case unquote(representation) do
          :relative -> Path.relative_to(root, File.cwd!())
          :home_relative -> String.replace_prefix(root, System.user_home!(), "~")
        end

      refute Path.type(configured_root) == :absolute
      literal_root = Path.join(File.cwd!(), configured_root)

      on_exit(fn ->
        File.rm_rf(literal_root)
        File.rm_rf(root)
      end)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: configured_root, tracker_kind: "memory")

      ProviderMeterProbe.observe(:codex, probe_agent: RecordingAgent, backend_configs: %{})

      assert_received {:probe_workspace, workspace}
      assert workspace == Path.join(root, "usage-probe")
      assert File.dir?(workspace)
    end
  end
end
