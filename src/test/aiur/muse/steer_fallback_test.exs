defmodule Aiur.Muse.SteerFallbackTest do
  use ExUnit.Case, async: true

  alias Aiur.Muse.{Transport, TurnLoop}

  setup do
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, {:line, 65_536}])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    %{session: %{port: port, thread_id: "session", gateway: make_ref()}}
  end

  test "a failed steer write restores the claim once without acknowledging it", %{session: session} do
    owner = self()

    task =
      run(session, fn ->
        Port.close(session.port)
        send(self(), {:muse_prestart, terminal()})
        claim(owner)
      end)

    wake(task)
    assert {:ok, %{result: :turn_completed}} = Task.await(task, :infinity)
    assert_received {:failed, :port_closed}
    refute_received {:failed, _}
    refute_received {:delivered, _}
  end

  test "pause before steer suppresses the claim and native steer frame", %{session: session} do
    owner = self()

    task =
      run(session, fn ->
        send(owner, :claimed)
        claim(owner)
      end)

    send(task.pid, {:pause_agent, 77, 4})
    wake(task)

    assert {:ok, %{"method" => "turn/interrupt", "id" => id, "params" => %{"commandId" => command}}} =
             Transport.receive_frame(session.port, 30_000)

    send(task.pid, {:muse_prestart, %{"id" => id, "result" => %{"commandId" => command, "status" => "accepted", "turnId" => "turn"}}})
    send(task.pid, {:muse_prestart, terminal()})
    assert {:paused, %{control: %{request_id: 77, generation: 4}}} = Task.await(task, :infinity)
    refute_received :claimed
    refute_received {:delivered, _}
    assert written_frames(session.port) == []
  end

  test "port exit restores an outstanding steer with a cause-neutral close reason", %{session: session} do
    owner = self()

    task =
      run(session, fn ->
        send(self(), {session.port, {:exit_status, 73}})
        claim(owner)
      end)

    wake(task)
    assert {:error, {:native_port_exit, 73}} = Task.await(task, :infinity)
    assert_received {:failed, :turn_closed}
    refute_received {:failed, _}
    refute_received {:delivered, _}
    assert [%{"method" => "turn/steer"}] = written_frames(session.port)
  end

  defp run(session, callback) do
    Task.async(fn ->
      TurnLoop.await(session, "turn", %{identifier: "MUSE-1"}, make_ref(), [on_steer_claim: callback, on_message: fn _ -> :ok end], 30_000)
    end)
  end

  defp wake(task), do: send(task.pid, {:agent_queue_updated, "MUSE-1", 1, :steer})

  defp claim(owner) do
    {:deliver_text, "0.1", fn metadata -> send(owner, {:delivered, metadata}) end, fn reason -> send(owner, {:failed, reason}) end}
  end

  # cat echoes writes in order; the marker fences every frame the task wrote.
  defp written_frames(port) do
    :ok = Transport.send_frame(port, %{"jsonrpc" => "2.0", "method" => "test/barrier"})
    collect_frames(port)
  end

  defp collect_frames(port) do
    case Transport.receive_frame(port, 30_000) do
      {:ok, %{"method" => "test/barrier"}} -> []
      {:ok, frame} -> [frame | collect_frames(port)]
    end
  end

  defp terminal do
    %{"method" => "turn/completed", "params" => %{"sessionId" => "session", "turnId" => "turn", "terminal" => "completed", "viewCursor" => "done", "sourceRange" => %{}}}
  end
end
