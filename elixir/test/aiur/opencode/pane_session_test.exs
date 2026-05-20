defmodule Aiur.Opencode.PaneSessionTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Opencode.PaneSession

  test "returns {:error, _} when opencode serve fails to start instead of crashing the caller" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      opencode_command: "definitely-not-opencode-#{System.unique_integer([:positive])}"
    )

    workspace =
      Path.join(System.tmp_dir!(), "aiur-pane-session-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    parent = self()

    pid =
      spawn(fn ->
        result = PaneSession.start("MT-PANE-#{System.unique_integer([:positive])}", workspace)
        send(parent, {:result, result})
      end)

    ref = Process.monitor(pid)

    receive do
      {:result, {:error, _reason}} -> :ok
      {:result, other} -> flunk("expected {:error, _}, got #{inspect(other)}")
      {:DOWN, ^ref, :process, _, reason} -> flunk("PaneSession.start raised: #{inspect(reason)}")
    after
      35_000 -> flunk("PaneSession.start did not return within 35s")
    end
  end
end
