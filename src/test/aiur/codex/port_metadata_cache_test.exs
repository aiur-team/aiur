defmodule Aiur.Codex.PortMetadataCacheTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Codex.{AppServerPort, TurnEvents}

  test "startup metadata is reused for deltas without executable lookup or OS commands" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "exec cat")
    caller = self()

    runner =
      spawn_link(fn ->
        {:ok, port} = AppServerPort.start_port(File.cwd!(), nil, nil, nil)
        metadata = AppServerPort.port_metadata(port)
        send(caller, {:started, self(), metadata})

        receive do
          :stream ->
            results = for _ <- 1..100, do: TurnEvents.metadata_from_message(port, %{"usage" => %{"output_tokens" => 1}})
            send(caller, {:metadata, results})
        end

        receive do
          :stop ->
            AppServerPort.stop_port(port)
            send(caller, {:stopped, AppServerPort.port_metadata(port)})
        end
      end)

    on_exit(fn -> if Process.alive?(runner), do: Process.exit(runner, :kill) end)
    receive_barrier({:started, ^runner, metadata})
    assert metadata.agent_process_group_id == metadata.codex_app_server_pid

    assert [] ==
             trace_os_calls(runner, fn ->
               send(runner, :stream)
               receive_barrier({:metadata, results})
               assert length(results) == 100
               assert Enum.all?(results, &(&1 == Map.put(metadata, :usage, %{"output_tokens" => 1})))
             end)

    send(runner, :stop)
    receive_barrier({:stopped, stopped_metadata})
    assert stopped_metadata == %{}
  end

  test "each port keeps its own metadata and remote metadata never acquires a local group" do
    executable = System.find_executable("cat") |> String.to_charlist()
    local = Port.open({:spawn_executable, executable}, [:binary])
    remote = Port.open({:spawn_executable, executable}, [:binary])

    try do
      local_metadata = AppServerPort.port_metadata(local)
      remote_metadata = AppServerPort.port_metadata(remote, "worker-1")
      refute local_metadata.provider_pid == remote_metadata.provider_pid
      refute Map.has_key?(remote_metadata, :agent_process_group_id)
      assert TurnEvents.metadata_from_message(local, %{}) == local_metadata
      assert TurnEvents.metadata_from_message(remote, %{}) == remote_metadata
    after
      AppServerPort.stop_port(local)
      AppServerPort.stop_port(remote)
    end
  end

  defp trace_os_calls(runner, exercise) do
    patterns = [{System, :cmd, 3}, {System, :find_executable, 1}]
    Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(runner, true, [:call])

    try do
      exercise.()
      ref = :erlang.trace_delivered(runner)
      receive_barrier({:trace_delivered, ^runner, ^ref})
      {:messages, messages} = Process.info(self(), :messages)
      Enum.filter(messages, &match?({:trace, ^runner, :call, _}, &1))
    after
      :erlang.trace(runner, false, [:call])
      Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local]))
    end
  end
end
