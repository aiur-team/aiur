defmodule Aiur.BuildQueue.BootTest do
  use Aiur.TestSupport
  alias Aiur.Application, as: AiurApp
  alias Aiur.BuildQueue
  alias Aiur.BuildQueue.Server

  test "disabled queue is absent from boot children" do
    configure(false)
    refute Server in children(true)
    assert BuildQueue.status() == :disabled
    assert %{status: :disabled, queues: []} = BuildQueue.show()
    assert {:error, :disabled} = BuildQueue.reconcile_now()
    assert {:error, :disabled} = BuildQueue.recover()
  end

  test "recording gate excludes queue even when enabled" do
    configure(true)
    refute Server in children(false)
  end

  test "enabled capable queue follows Orchestrator in boot children" do
    configure(true, "memory")
    modules = children(true)
    assert Server in modules
    assert Enum.find_index(modules, &(&1 == Aiur.Orchestrator)) < Enum.find_index(modules, &(&1 == Server))
  end

  test "unsupported tracker is absent from boot children" do
    configure(true, "linear")
    refute Server in children(true)
    assert BuildQueue.status() == :unsupported_tracker
  end

  defp configure(enabled, tracker \\ "memory") do
    path = Aiur.Workflow.workflow_file_path()
    write_workflow_file!(path, tracker_kind: tracker)
    write_workflow_file_atomic!(path, File.read!(path) <> "\nbuild_queue:\n  enabled: #{enabled}\n")
    :ok = Aiur.WorkflowStore.force_reload()
  end

  defp children(recording) do
    AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: false, recording?: recording, tailscale_funnel?: false)
    |> Enum.map(fn
      {module, _} -> module
      module -> module
    end)
  end
end
