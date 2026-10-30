defmodule Aiur.Listener.ConformanceTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentQueue, AgentQueueStore}
  alias Aiur.AgentRunner.QueueTurn
  alias Aiur.Listener.{Effective, ModeStore, Scheduler, Spec}
  alias Aiur.Orchestrator.{OperatorMessages, State}
  alias Aiur.Orchestrator.OperatorMessages.DeliveryPolicy

  @delivery_modes [:steer, :sync, :async]
  @modes @delivery_modes ++ [:mute]
  @not_applicable %{
    agent_self_mode: "Khala agents may lower their own mode; Aiur v1 retains human and Executor mode control",
    owner_lock: "Khala owner locks have no counterpart in Aiur v1's operator authority model",
    channel_addressing: "Khala mention parsing is absent; operator sends are addressed, agent broadcasts are not, actionable declared-blocker signals are addressed dependency inputs",
    start: "Hook session registration has no Aiur queue-claim boundary",
    prompt: "Claude hook prompt busy/age rules do not apply to Aiur's runner-owned turn boundaries",
    continuation: "Hook Stop continuations do not end the Aiur turn"
  }

  setup do
    dir = Aiur.TestSupport.tmp_root!("listener-conformance")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "all shared wake rows match the production wake rule" do
    rows = Application.app_dir(:aiur, "priv/listener_spec/v1/wake.v1.json") |> File.read!() |> Jason.decode!()
    assert length(rows) == 16

    for row <- rows do
      mode = Enum.find(@modes, &(Atom.to_string(&1) == row["mode"]))
      assert Scheduler.wakes?(mode, row["addressed"], row["from_agent"]) == row["wakes"], inspect(row)
    end
  end

  test "control declares the spec notice backlog policy" do
    golden = Application.app_dir(:aiur, "priv/listener_spec/v1/goldens/control-record-notice.json") |> File.read!() |> Jason.decode!()
    harness = %{source: :session, harness_id: "codex", callbacks: %{steer: :none}, primitives: %{turn_boundary_start: true, hard_interrupt: :none, pull_tool: false}}
    view = Effective.compute(%{requested: :sync, version: 1, actor: :human}, harness)
    control = view |> Jason.encode!() |> Jason.decode!() |> Map.take(Map.keys(golden))
    assert control == golden
  end

  test "every shared row is classified and modeled boundaries agree with delivers" do
    rows = scheduler_rows!()

    mismatches =
      Enum.flat_map(rows, fn row ->
        case boundary(row) do
          {:not_applicable, reason} ->
            assert Map.fetch!(@not_applicable, reason) != ""
            []

          event ->
            scheduler_mismatches(row, event)
        end
      end)

    assert mismatches == [],
           "aiur disagrees with scheduler.v1.json:\n" <> Enum.map_join(mismatches, "\n", &inspect(&1, limit: :infinity, printable_limit: :infinity))
  end

  test "held async and mute bodies never claim at either boundary or directly wake an idle runner" do
    async_rows = Enum.filter(scheduler_rows!(), &(&1["mode"] in ["async", "mute"]))
    assert async_rows != []

    for row <- async_rows do
      {state, item, id} = queued(row)
      assert_async_empty(claim(state, id, :tool), state, row, :tool)
      assert_async_empty(claim(state, id, :stop), state, row, :stop)
      assert_async_empty(OperatorMessages.claim_next_queue_item_call(state, id), state, row, :queue_drain)
      entry = %{pid: self(), control: %{status: :sleeping}}
      assert :ok = DeliveryPolicy.notify_running_queue_update(state, entry, item)
      item_id = item.id
      assert_received {:agent_queue_updated, ^id, ^item_id, false}
    end
  end

  test "all shared modes round-trip through persistence, defaulting to sync", %{dir: dir} do
    assert Spec.status() == :ok, "spec unavailable"
    assert Enum.sort(Spec.modes()) == Enum.sort(Enum.map(@modes, &Atom.to_string/1))
    opts = [dir: dir, repo_name: "conformance"]
    assert ModeStore.get("default", opts).requested == :sync

    for mode <- @modes do
      assert {:ok, record} = ModeStore.put(Atom.to_string(mode), mode, 0, %{actor: :human}, opts)
      assert record.requested == mode
      assert ModeStore.get(Atom.to_string(mode), opts).requested == mode
    end
  end

  test "addressed operator sends follow the shared wake table without reading held bodies" do
    assert Spec.status() == :ok
    rows = Application.app_dir(:aiur, "priv/listener_spec/v1/wake.v1.json") |> File.read!() |> Jason.decode!()
    assert rows != []
    modeled = Enum.filter(rows, &(&1["addressed"] == true and &1["from_agent"] == false))
    assert Enum.sort(Enum.map(modeled, & &1["mode"])) == Enum.sort(Enum.map(@modes, &Atom.to_string/1))

    for row <- rows -- modeled do
      assert row["from_agent"] or not row["addressed"]
      assert Map.fetch!(@not_applicable, :channel_addressing) != ""
    end

    for row <- modeled do
      {state, item, id} = queued(row)
      entry = %{identifier: id, pid: self(), control: %{status: :sleeping}}
      store = Scheduler.notify_enqueued(state, entry, item)
      expected = row["wakes"]
      assert_received {:agent_queue_updated, ^id, _, ^expected}

      if row["mode"] in ["async", "mute"] do
        assert AgentQueueStore.get(store, item.id).status == :pending
        assert AgentQueueStore.get(store, item.id).body.text == "shared spec row"
      end

      nudges = Enum.filter(AgentQueueStore.list_pending(store, id), &(&1.event_type == :listener_ping))
      assert length(nudges) == if(row["mode"] == "async" and expected, do: 1, else: 0)

      for nudge <- nudges do
        text = QueueTurn.queue_item_text(nudge)
        assert text =~ "aiur_read_messages"
        refute text =~ "shared spec row"
      end
    end
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
        assert Enum.sort(Map.keys(view.support)) == Enum.sort(@delivery_modes)
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

  defp assert_async_empty(result, state, row, boundary) do
    unless match?({:reply, :empty, ^state}, result) do
      flunk("async item claimed at #{boundary}: #{inspect(row, limit: :infinity, printable_limit: :infinity)}")
    end
  end

  defp scheduler_mismatches(row, event) do
    {state, item, id} = queued(row)
    result = claim(state, id, event)
    context = inspect(row, limit: :infinity, printable_limit: :infinity)

    case {row["delivers"], result} do
      {true, {:reply, {:ok, claimed}, next}} ->
        assert claimed.id == item.id, context
        assert claimed.body.text == "shared spec row", context
        assert AgentQueueStore.get(next.queue_store, item.id).status == :delivered, context
        []

      {false, {:reply, :empty, ^state}} ->
        assert AgentQueueStore.get(state.queue_store, item.id).status == :pending, context
        []

      {expected, _} ->
        actual =
          case result do
            {:reply, {:ok, _}, _} -> true
            {:reply, :empty, ^state} -> false
            _ -> :unexpected_reply
          end

        [%{row: row, boundary: event, expected: expected, actual: actual}]
    end
  end

  defp scheduler_rows! do
    rows = Spec.scheduler_rows()
    assert is_list(rows) and rows != [], "spec unavailable: #{inspect(rows)}"
    rows
  end

  defp boundary(%{"harness" => harness, "event" => event, "mode" => mode} = row)
       when harness in ["claude", "codex"] and event in ["start", "prompt", "tool", "stop"] and mode in ["steer", "sync", "async", "mute"] do
    classify_boundary(row)
  end

  defp boundary(row), do: flunk("unclassified scheduler row: #{inspect(row)}")

  defp classify_boundary(%{"event" => "start"}), do: {:not_applicable, :start}
  defp classify_boundary(%{"event" => "prompt", "harness" => "claude"}), do: {:not_applicable, :prompt}
  defp classify_boundary(%{"event" => "prompt"}), do: :stop
  defp classify_boundary(%{"event" => "stop", "continuation" => true}), do: {:not_applicable, :continuation}
  defp classify_boundary(%{"event" => "tool"}), do: :tool
  defp classify_boundary(%{"event" => "stop"}), do: :stop

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
