defmodule Aiur.Listener.ConformanceTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentQueue, AgentQueueStore}
  alias Aiur.Listener.{Effective, ModeStore, Scheduler, Spec}
  alias Aiur.Orchestrator.{OperatorMessages, State}
  alias Aiur.Orchestrator.OperatorMessages.DeliveryPolicy

  @modes [:steer, :sync, :async]
  @not_applicable %{
    mute: "Khala-only mode; Aiur exposes steer, sync and async",
    start: "Hook session registration has no Aiur queue-claim boundary",
    prompt: "Claude hook prompt busy/age rules do not apply to Aiur's runner-owned turn boundaries",
    continuation: "Hook Stop continuations do not end the Aiur turn"
  }

  setup do
    dir = Aiur.TestSupport.tmp_root!("listener-conformance")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    %{dir: dir}
  end

  # Future regression guards: this test-only change locks existing behavior to the vendored contract.
  test "every shared row is classified and modeled boundaries agree with delivers" do
    rows = scheduler_rows!()

    for row <- rows do
      case boundary(row) do
        {:not_applicable, reason} ->
          assert Map.fetch!(@not_applicable, reason) != ""

        event ->
          {state, item, id} = queued(row)
          result = claim(state, id, event)

          if row["delivers"] do
            assert {:reply, {:ok, claimed}, next} = result, inspect(row)
            assert claimed.id == item.id
            assert claimed.body.text == "shared spec row"
            assert AgentQueueStore.get(next.queue_store, item.id).status == :delivered
          else
            assert {:reply, :empty, ^state} = result, inspect(row)
            assert AgentQueueStore.get(state.queue_store, item.id).status == :pending
          end
      end
    end
  end

  test "async rows never claim at either boundary or wake an idle runner" do
    async_rows = Enum.filter(scheduler_rows!(), &(&1["mode"] == "async"))
    assert async_rows != []

    for row <- async_rows do
      {state, item, id} = queued(row)
      assert {:reply, :empty, ^state} = claim(state, id, :tool), inspect(row)
      assert {:reply, :empty, ^state} = claim(state, id, :stop), inspect(row)
      assert {:reply, :empty, ^state} = OperatorMessages.claim_next_queue_item_call(state, id), inspect(row)
      entry = %{pid: self(), control: %{status: :sleeping}}
      assert :ok = DeliveryPolicy.notify_running_queue_update(state, entry, item)
      item_id = item.id
      assert_received {:agent_queue_updated, ^id, ^item_id, false}
    end
  end

  test "shared modes match persisted Aiur modes plus Khala-only mute, defaulting to sync", %{dir: dir} do
    assert Enum.sort(Spec.modes()) == Enum.sort(Enum.map(@modes, &Atom.to_string/1) ++ ["mute"])
    opts = [dir: dir, repo_name: "conformance"]
    assert ModeStore.get("default", opts).requested == :sync

    for mode <- @modes do
      assert {:ok, record} = ModeStore.put(Atom.to_string(mode), mode, 0, %{actor: :human}, opts)
      assert record.requested == mode
      assert ModeStore.get(Atom.to_string(mode), opts).requested == mode
    end

    assert {:error, :invalid_mode} = ModeStore.put("mute", :mute, 0, %{actor: :human}, opts)
  end

  test "Effective support statuses and steer carriers belong to the shared schema" do
    assert Spec.status() == :ok, "spec unavailable"
    schema = Application.app_dir(:aiur, "priv/listener_spec/v1/listening-mode.v1.schema.json") |> File.read!() |> Jason.decode!()
    carriers = get_in(schema, ["$defs", "steerSupportEntry", "properties", "steer_carrier", "enum"])
    statuses = Spec.support_statuses()

    harnesses =
      for backend <- ["codex", "claude", "claude-repl"], turn <- [false, true], interrupt <- [:none, :in_band, :out_of_band], native <- [:none, :native], pull <- [false, true] do
        %{harness_id: backend, source: :session, callbacks: %{steer: native}, primitives: %{turn_boundary_start: turn, hard_interrupt: interrupt, pull_tool: pull}}
      end

    observed =
      for harness <- [nil, %{primitives: :unknown, source: :session} | harnesses], requested <- @modes, accepted <- [false, true], installed <- [false, true] do
        view = Effective.compute(%{requested: requested, version: 0, actor: :default}, harness, emulated_interrupt_accepted?: accepted, pull_tool_installed?: installed)
        assert Enum.sort(Map.keys(view.support)) == Enum.sort(@modes)
        assert is_nil(view.effective) or Atom.to_string(view.effective) in Spec.modes()

        for {_mode, support} <- view.support do
          assert Atom.to_string(support.status) in statuses
          if support.carrier, do: assert(Atom.to_string(support.carrier) in carriers)
          support
        end
      end

    # Effective currently has no blocked_without_wrapper branch.
    entries = List.flatten(observed)
    assert entries |> Enum.map(&Atom.to_string(&1.status)) |> Enum.uniq() |> Enum.sort() == Enum.sort(statuses -- ["blocked_without_wrapper"])
    assert entries |> Enum.reject(&is_nil(&1.carrier)) |> Enum.map(&Atom.to_string(&1.carrier)) |> Enum.uniq() |> Enum.sort() == Enum.sort(carriers)
  end

  defp scheduler_rows! do
    rows = Spec.scheduler_rows()
    assert is_list(rows) and rows != [], "spec unavailable: #{inspect(rows)}"
    rows
  end

  defp boundary(%{"harness" => harness, "event" => event, "mode" => mode} = row)
       when harness in ["claude", "codex"] and event in ["start", "prompt", "tool", "stop"] and mode in ["steer", "sync", "async", "mute"] do
    classify_boundary(row, harness, event, mode)
  end

  defp boundary(row), do: flunk("unclassified scheduler row: #{inspect(row)}")

  defp classify_boundary(row, harness, event, mode) do
    cond do
      mode == "mute" -> {:not_applicable, :mute}
      event == "start" -> {:not_applicable, :start}
      event == "prompt" and harness == "claude" -> {:not_applicable, :prompt}
      event == "prompt" -> :stop
      event == "stop" and row["continuation"] -> {:not_applicable, :continuation}
      event == "tool" -> :tool
      event == "stop" -> :stop
    end
  end

  defp queued(row) do
    id = "conformance-#{System.unique_integer([:positive])}"
    mode = Enum.find(@modes, &(Atom.to_string(&1) == row["mode"]))
    view = %{effective: mode, support: %{steer: %{carrier: :native}}}
    payload = AgentQueue.operator_message(id, "shared spec row")
    payload = %{payload | delivery: Scheduler.restamp_fun(view).(payload.delivery)}
    {store, item} = AgentQueueStore.enqueue(AgentQueueStore.new(), payload)
    {%State{queue_store: store}, item, id}
  end

  defp claim(state, id, :tool), do: OperatorMessages.claim_next_checkpoint_queue_item_call(state, id)
  defp claim(state, id, :stop), do: OperatorMessages.claim_next_operator_queue_item_call(state, id)
end
