defmodule Aiur.WorkflowStore.ProjectReloadTest do
  use Aiur.TwoProjectsCase, async: false

  alias Aiur.TestSupport.WorkflowFiles
  alias Aiur.WorkflowStore.Reload

  test "a config change in one project wakes only that project's subscribers", %{a: a, b: b} do
    topic_a = in_project(a, &Reload.configuration_topic/0)
    topic_b = in_project(b, &Reload.configuration_topic/0)
    assert topic_a == "workflow_store:configuration:o/a"
    assert topic_b == "workflow_store:configuration:o/b"

    me = self()
    for {tag, topic} <- [a: topic_a, b: topic_b], do: relay(me, tag, topic)

    WorkflowFiles.write_workflow_file!(a.config_path, tracker_kind: "memory", max_concurrent_agents: 7)
    assert :ok = in_project(a, fn -> Aiur.WorkflowStore.force_reload(15_000) end)

    assert_receive {:woke, :a, _generation}, 5_000
    refute_receive {:woke, :b, _}, 200
    assert 7 = in_project(a, fn -> Aiur.Config.settings!().agent.max_concurrent_agents end)
    refute 7 == in_project(b, fn -> Aiur.Config.settings!().agent.max_concurrent_agents end)
  end

  test "the telemetry writer records the reload of a project that starts after it", %{root: root} do
    path = Path.join(root, "telemetry.ndjson")
    {:ok, settings} = Agent.start_link(fn -> %{agent: %{max_concurrent_agents: 1}} end)
    builder = fn -> Aiur.RunTelemetry.RunContext.build(Agent.get(settings, & &1)) end
    # The production order: the writer is up before any project registers.
    {:ok, writer} = Aiur.RunTelemetry.Writer.start_link(name: nil, path: path, boot_id: "reload", context_builder: builder)
    Aiur.RunTelemetry.Writer.flush(writer)
    count = fn -> path |> File.read!() |> String.split("\n", trim: true) |> Enum.count(&(&1 =~ "run_context")) end
    before = count.()

    c = project("o/c", root)
    on_exit(fn -> Aiur.Project.Table.drop("o/c") end)
    assert {:ok, _} = Aiur.Project.Supervisors.start_project(c)

    Agent.update(settings, &put_in(&1, [:agent, :max_concurrent_agents], 9))
    WorkflowFiles.write_workflow_file!(c.config_path, tracker_kind: "memory", max_concurrent_agents: 7)
    assert :ok = in_project(c, fn -> Aiur.WorkflowStore.force_reload(15_000) end)
    Aiur.RunTelemetry.Writer.flush(writer)

    assert count.() == before + 1
    GenServer.stop(writer)
  end

  defp relay(me, tag, topic) do
    {:ok, pid} =
      Task.start_link(fn ->
        :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, topic)
        send(me, {:subscribed, tag})

        receive do
          {:workflow_config_updated, generation} -> send(me, {:woke, tag, generation})
        end
      end)

    assert_receive {:subscribed, ^tag}, 1_000
    pid
  end
end
