defmodule Aiur.ProgressCheckin.WorkerTest do
  @moduledoc """
  Drives the worker with a fake orchestrator (a process answering
  `:list_running_active_identifiers`) and a capture-publisher tuple so
  the test sees every `(topic, payload)` pair without involving the
  real Exchange.
  """

  use ExUnit.Case, async: false

  alias Aiur.ProgressCheckin.Worker

  setup do
    parent = self()

    fake_orchestrator =
      spawn_link(fn -> fake_orchestrator_loop(parent, ["99", "100", "101"]) end)

    publisher = fn topic, payload ->
      send(parent, {:published, topic, payload})
      {:ok, %{id: 1, subscribers: 0}}
    end

    %{fake_orch: fake_orchestrator, publisher: publisher}
  end

  defp fake_orchestrator_loop(parent, identifiers) do
    receive do
      {:"$gen_call", from, :list_running_active_identifiers} ->
        send(parent, :orchestrator_called)
        GenServer.reply(from, identifiers)
        fake_orchestrator_loop(parent, identifiers)

      {:set_identifiers, new_ids} ->
        fake_orchestrator_loop(parent, new_ids)

      _ ->
        fake_orchestrator_loop(parent, identifiers)
    end
  end

  test "tick fans out one publish per active identifier", %{
    fake_orch: orch,
    publisher: publisher
  } do
    {:ok, pid} =
      Worker.start_link(
        name: nil,
        orchestrator: orch,
        publisher: publisher,
        start_paused?: true
      )

    send(pid, :tick)

    assert_receive {:published, "ticket.99.operator.progress_request", %{"kind" => "progress_request"}},
                   500

    assert_receive {:published, "ticket.100.operator.progress_request", _}, 500
    assert_receive {:published, "ticket.101.operator.progress_request", _}, 500
  end

  test "publish payload includes the operator-source tag and instruction text", %{
    fake_orch: orch,
    publisher: publisher
  } do
    {:ok, pid} =
      Worker.start_link(
        name: nil,
        orchestrator: orch,
        publisher: publisher,
        start_paused?: true
      )

    send(pid, :tick)

    assert_receive {:published, _topic, payload}, 500

    assert payload.source == :system
    assert payload["source"] == "operator"
    assert payload["kind"] == "progress_request"
    assert is_binary(payload["message"])
    assert payload["message"] =~ "progress.checkin"
    assert payload["message"] =~ "1–10"
  end

  test "tick reschedules itself", %{fake_orch: orch, publisher: publisher} do
    {:ok, pid} =
      Worker.start_link(
        name: nil,
        orchestrator: orch,
        publisher: publisher,
        interval_ms: 60,
        start_paused?: true
      )

    send(pid, :tick)
    assert_receive :orchestrator_called, 500

    # next tick fires automatically ~60ms later
    assert_receive :orchestrator_called, 500
  end

  test "empty active set publishes nothing", %{publisher: publisher} do
    parent = self()
    empty_orch = spawn_link(fn -> fake_orchestrator_loop(parent, []) end)

    {:ok, pid} =
      Worker.start_link(
        name: nil,
        orchestrator: empty_orch,
        publisher: publisher,
        start_paused?: true
      )

    send(pid, :tick)
    assert_receive :orchestrator_called, 500
    refute_receive {:published, _topic, _payload}, 100
  end

  test "orchestrator down → no crash, no publishes" do
    parent = self()
    publisher = fn topic, payload -> send(parent, {:should_not_publish, topic, payload}) end

    dead = spawn(fn -> :ok end)
    Process.sleep(10)
    refute Process.alive?(dead)

    {:ok, pid} =
      Worker.start_link(
        name: nil,
        orchestrator: dead,
        publisher: publisher,
        start_paused?: true
      )

    send(pid, :tick)
    Process.sleep(50)
    assert Process.alive?(pid)
    refute_receive {:should_not_publish, _, _}, 100
  end
end
