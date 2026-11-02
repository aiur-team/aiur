defmodule AiurWeb.Build.IndexAgentRecoveryTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.Index

  test "an unavailable ready agent read keeps its last observed rows and age" do
    pid = start_index()
    observed_at = now()
    initial = put_in(parts(), [:now, :rows], %{"12" => now_row(12)})
    complete_read(pid, initial)

    send(pid, {:ticket_activity_changed, %{}})
    :sys.get_state(pid)
    send(pid, :flush)
    receive_barrier({:recovery_read, worker, dirty})
    assert MapSet.member?(dirty, :now)
    unavailable = put_in(initial, [:now], %{rows: %{}, source: %{state: "unavailable", observed_at: nil, reason: "fleet_unavailable"}})
    send(worker, {:return, unavailable})
    assert await_read_finish(pid, 100)

    assert {:ok, snapshot} = Index.window(pid, "Etc/UTC")
    assert Enum.map(snapshot.sections.now, & &1.id) == ["12"]
    assert snapshot.sources.agents.state == "stale"
    assert snapshot.sources.agents.observed_at == observed_at
  end

  test "a cold Index keeps unknown age unavailable, retries, and publishes a real observation" do
    unavailable = parts() |> put_in([:now], %{rows: %{}, source: %{state: "unavailable", observed_at: nil, reason: "fleet_unavailable"}})
    pid = start_index(unavailable)

    assert {:ok, first} = Index.window(pid, "Etc/UTC")
    assert first.sources.agents.state == "unavailable"
    assert first.sources.agents.observed_at == nil
    assert_receive {:recovery_timer, ^pid, :flush, _delay}, 1_000

    ready = put_in(parts(), [:now, :rows], %{"12" => now_row(12)})
    send(pid, :flush)
    receive_barrier({:recovery_read, worker, dirty})
    assert MapSet.member?(dirty, :now)
    send(worker, {:return, ready})
    assert await_read_finish(pid, 100)

    assert {:ok, recovered} = Index.window(pid, "Etc/UTC")
    assert Enum.map(recovered.sections.now, & &1.id) == ["12"]
    assert recovered.sources.agents.state == "ok"
    assert is_integer(recovered.sources.agents.observed_at)
  end

  defp start_index(initial \\ parts()) do
    parent = self()

    opts = [
      name: nil,
      subscribe: fn -> :ok end,
      read: fn dirty, _previous, _opts ->
        send(parent, {:recovery_read, self(), dirty})
        receive(do: ({:return, value} -> value))
      end,
      timer: fn server, message, ms ->
        send(parent, {:recovery_timer, server, message, ms})
        make_ref()
      end,
      daemon_timer: fn _, _, _ -> make_ref() end,
      daemon_read: fn _ -> %{state: "live", heartbeat_at: 1, observed_at: 2} end,
      clock: &now/0
    ]

    pid = start_supervised!({Index, opts}, id: {:index_agent_recovery, System.unique_integer([:positive])})
    receive_barrier({:recovery_read, worker, :all})
    send(worker, {:return, initial})
    true = await_read_finish(pid, 100)
    pid
  end

  defp complete_read(pid, value) do
    send(pid, {:ticket_activity_changed, %{}})
    :sys.get_state(pid)
    send(pid, :flush)
    receive_barrier({:recovery_read, worker, _dirty})
    send(worker, {:return, value})
    assert await_read_finish(pid, 100)
  end

  defp await_read_finish(_pid, 0), do: false

  defp await_read_finish(pid, attempts) do
    if is_nil(:sys.get_state(pid).task) do
      true
    else
      Process.sleep(10)
      await_read_finish(pid, attempts - 1)
    end
  end
end
