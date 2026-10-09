defmodule Aiur.BuildQueue.ClearTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.BuildQueue.{Model, MutationCLI, Server, Store}
  alias Aiur.Config.Schema
  @empty %{queues: [], items: [], edges: [], intents: [], latches: []}

  defmodule Boundary do
    def load, do: Store.load()
    def rebuild(doc), do: Store.rebuild(doc)

    def save(doc) do
      state = Agent.get(__MODULE__, & &1)
      if (state.fail_outcome and Enum.any?(doc.intents, &(&1.outcome == :ok))) or (state.fail_empty and doc.intents == []), do: {:error, :disk_full}, else: Store.save(doc)
    end

    def open_issue_labels(_), do: Agent.get(__MODULE__, &if(&1.available, do: {:ok, &1.labels, &1.now}, else: {:error, :offline}))
    def blocked_by(_), do: {:ok, []}
    def status(_), do: :unavailable
    def notify_demand(_), do: :ok

    def remove_label(id, label) do
      Agent.get_and_update(__MODULE__, fn state ->
        if state.pause do
          {{:error, {:github, :local_hold, :budget}}, state}
        else
          {:ok, %{state | calls: state.calls ++ [{id, label}], labels: Map.update!(state.labels, id, &%{labels: List.delete(&1.labels, label)})}}
        end
      end)
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "clear-3074-#{System.unique_integer([:positive])}")
    previous = Application.fetch_env(:aiur, :decision_state_dir)
    Application.put_env(:aiur, :decision_state_dir, root)

    boundary =
      start_supervised!(
        {Agent,
         fn ->
           %{
             labels: %{"1" => %{labels: ["agent:queued", "agent:todo"]}, "2" => %{labels: ["agent:queued"]}, "3" => %{labels: ["agent:todo"]}},
             now: 1_000,
             calls: [],
             pause: false,
             fail_outcome: false,
             fail_empty: false,
             available: true
           }
         end}
      )

    Process.register(boundary, Boundary)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :decision_state_dir, value)
        :error -> Application.delete_env(:aiur, :decision_state_dir)
      end

      File.rm_rf!(root)
    end)

    :ok = Store.save(document())
    assert Store.load() == {:ok, document()}
    :ok
  end

  test "clear removes markers from every open issue and keeps todo" do
    pid = server()
    assert clear(pid) == {:ok, [{"clear", :ok}]}
    assert calls() == [{"1", "agent:queued"}, {"2", "agent:queued"}]
    assert labels() == %{"1" => %{labels: ["agent:todo"]}, "2" => %{labels: []}, "3" => %{labels: ["agent:todo"]}}
    assert Store.load() == {:ok, @empty}
    assert clear(pid) == {:ok, [{"clear", :ok}]}
    assert length(calls()) == 2
  end

  test "clear without yes exits one without any writes through CLI or direct RPC" do
    pid = server()
    before = Store.load()
    output = capture_io(fn -> assert Aiur.BuildQueueCLI.run(verb: :clear, remove_markers: true, server: pid, error_fun: &IO.puts/1) == 1 end)
    assert output =~ "requires --yes"
    assert GenServer.call(pid, {:mutate, {:clear, [remove_markers: true]}}) == {:error, :confirmation_required}
    assert Store.load() == before
    assert calls() == []
  end

  test "healthy recovery is refused and force rebuilds held sorted markers without old edges" do
    pid = server()
    before = Store.load()
    assert MutationCLI.execute(verb: :recover, server: pid) == {:ok, [{"recover", {:error, :store_present}}]}
    assert Store.load() == before
    assert MutationCLI.execute(verb: :recover, force: true, server: pid) == {:ok, [{"recover", :ok}]}
    assert {:ok, doc} = Store.load()
    assert [%{name: "recovered"}] = doc.queues
    assert Enum.map(doc.items, &{&1.issue_id, &1.position, &1.hold}) == [{"1", 0, :operator}, {"2", 1, :operator}]
    assert doc.edges == []
    assert calls() == []
  end

  test "clear refuses unavailable open listing without dropping membership" do
    pid = server()
    before = Store.load()
    Agent.update(Boundary, &%{&1 | available: false})
    assert clear(pid) == {:ok, [{"clear", {:error, :observation_unavailable}}]}
    assert Store.load() == before
    assert calls() == []
  end

  test "paced clear persists remaining work and resumes after restart" do
    pid = server(1)
    assert {:ok, [{"clear", {:error, {:marker_write_failed, _}}}]} = clear(pid)
    assert calls() == [{"1", "agent:queued"}]
    assert {:ok, %{items: [], queues: [], intents: intents}} = Store.load()
    assert Enum.any?(intents, &(&1.issue_id == "2" and &1.outcome == nil))
    stop_supervised!(Server)
    server(1)
    assert calls() == [{"1", "agent:queued"}, {"2", "agent:queued"}]
    assert Store.load() == {:ok, @empty}
  end

  test "budget hold reports writes paused and retry finishes clear" do
    pid = server()
    Agent.update(Boundary, &%{&1 | pause: true})
    assert clear(pid) == {:ok, [{"clear", {:error, :writes_paused}}]}
    assert GenServer.call(pid, :status) == :writes_paused
    assert {:ok, %{items: [], intents: [_ | _]}} = Store.load()
    Agent.update(Boundary, &%{&1 | pause: false})
    assert clear(pid) == {:ok, [{"clear", :ok}]}
    assert Store.load() == {:ok, @empty}
    assert labels()["1"].labels == ["agent:todo"]
  end

  test "restart after marker removal but before outcome save does not repeat removal" do
    pid = server()
    Agent.update(Boundary, &%{&1 | fail_outcome: true})
    assert {:ok, [{"clear", {:error, {:marker_write_failed, _}}}]} = clear(pid)
    assert calls() == [{"1", "agent:queued"}]
    assert {:ok, doc} = Store.load()
    assert Enum.any?(doc.intents, &(&1.issue_id == "1" and &1.outcome == nil))
    stop_supervised!(Server)
    Agent.update(Boundary, &%{&1 | fail_outcome: false})
    server()
    assert calls() == [{"1", "agent:queued"}, {"2", "agent:queued"}]
    assert Store.load() == {:ok, @empty}
  end

  test "paced clear resumes in the same daemon after the minute budget renews" do
    pid = server(1)
    assert {:ok, [{"clear", {:error, {:marker_write_failed, _}}}]} = clear(pid)
    assert calls() == [{"1", "agent:queued"}]
    Agent.update(Boundary, &%{&1 | now: 61_001})
    GenServer.call(pid, :reconcile_now)
    assert_received {:scheduled, ^pid, {:reconcile, token}}
    send(pid, {:reconcile, token})
    assert GenServer.call(pid, :status) == :running
    assert calls() == [{"1", "agent:queued"}, {"2", "agent:queued"}]
    assert Store.load() == {:ok, @empty}
  end

  test "final empty-store save failure does not report success" do
    pid = server()
    Agent.update(Boundary, &%{&1 | fail_empty: true})
    assert clear(pid) == {:ok, [{"clear", {:error, :store_unavailable}}]}
    assert {:ok, %{items: [], intents: [_ | _]}} = Store.load()
    assert calls() == [{"1", "agent:queued"}, {"2", "agent:queued"}]
    stop_supervised!(Server)
    Agent.update(Boundary, &%{&1 | fail_empty: false})
    server()
    assert Store.load() == {:ok, @empty}
    assert length(calls()) == 2
  end

  # Deliberate future regression guard: existing workspace and invalid-argument refusals must remain.
  test "recovery and clear retain daemon workspace guard and reject malformed options" do
    for opts <- [[verb: :recover], [verb: :clear, remove_markers: true, yes: true]] do
      assert {:error, :agent_workspace} = MutationCLI.execute(opts ++ [caller_agent_workspace: "/workspace", server: :absent])
    end

    for opts <- [[verb: :recover, force: "yes"], [verb: :recover, ids: ["1"]], [verb: :clear, yes: true], [verb: :clear, remove_markers: true, yes: "yes"]] do
      assert {:error, :invalid_arguments} = MutationCLI.execute(opts ++ [server: :absent])
    end
  end

  defp server(max_writes \\ 20) do
    owner = self()
    settings = %Schema{build_queue: %Schema.BuildQueue{enabled: true, max_writes_per_minute: max_writes}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}

    pid =
      start_supervised!(
        {Server,
         name: nil,
         tracker: Boundary,
         store: Boundary,
         claim_probe: Boundary,
         settings: {:ok, settings},
         clock: fn -> Agent.get(Boundary, & &1.now) end,
         sleep: fn _ -> :ok end,
         schedule: fn target, message, _ ->
           send(owner, {:scheduled, target, message})
           make_ref()
         end,
         exchange: :absent_clear_exchange}
      )

    assert_received {:scheduled, ^pid, {:reconcile, token}}
    send(pid, {:reconcile, token})
    GenServer.call(pid, :status)
    pid
  end

  defp clear(pid), do: MutationCLI.execute(verb: :clear, remove_markers: true, yes: true, server: pid)
  defp calls, do: Agent.get(Boundary, & &1.calls)
  defp labels, do: Agent.get(Boundary, & &1.labels)

  defp document do
    time = DateTime.from_unix!(0)
    queue = %Model.Queue{id: "q-ab12", name: "old", kind: :list, root: nil, held: true, generation: 0, created_at: time}
    item = %Model.Item{issue_id: "1", queue_id: queue.id, position: 0, hold: :operator, override: nil, promoted_at: nil, added_at: time}
    %{@empty | queues: [queue], items: [item], edges: [%Model.Edge{prerequisite: "2", dependent: "1", source: :list}]}
  end
end
