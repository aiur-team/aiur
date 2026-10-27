defmodule Aiur.BuildQueue.MutationCLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.BuildQueue.{Hints, Model, MutationCLI, Server}
  alias Aiur.Config.Schema
  @empty %{queues: [], items: [], edges: [], intents: [], latches: []}

  defmodule Boundary do
    def load, do: Agent.get(__MODULE__, &{:ok, &1.document})

    def save(doc) do
      Agent.get_and_update(__MODULE__, fn state ->
        if state.save_result == :ok, do: {:ok, %{state | document: doc}}, else: {state.save_result, state}
      end)
    end

    def open_issue_labels(_), do: Agent.get(__MODULE__, &if(Map.get(&1, :observation_unavailable?, false), do: {:error, :offline}, else: {:ok, Map.get(&1, :observation_labels, &1.labels), 1_000}))

    def issue_closure(id, _age),
      do: Agent.get_and_update(__MODULE__, &{Map.get(Map.get(&1, :closures, %{}), id, {:error, :not_found}), Map.update(&1, :closure_reads, [id], fn ids -> ids ++ [id] end)})

    def blocked_by(id), do: Agent.get(__MODULE__, &{:ok, Map.get(Map.get(&1, :dependencies, %{}), id, [])})

    def ticket_pull_request(id) do
      Agent.get_and_update(__MODULE__, fn state ->
        prs = Map.get(state, :prs, %{})

        case prs[id] do
          [pr | rest] -> {{:ok, pr}, Map.put(state, :prs, Map.put(prs, id, rest))}
          pr -> {{:ok, pr}, state}
        end
      end)
    end

    def ensure_labels(_), do: :ok

    def add_label(id, label) do
      case Agent.get(__MODULE__, & &1.marker_result) do
        :ok -> edit(id, &Enum.uniq(&1 ++ [label]))
        error -> error
      end
    end

    def remove_label(id, label), do: edit(id, &List.delete(&1, label))
    def update_issue_state(id, "todo", _opts), do: add_label(id, "agent:todo")
    defp edit(id, fun), do: Agent.update(__MODULE__, fn state -> %{state | labels: Map.update!(state.labels, id, &%{labels: fun.(&1.labels)})} end)
    def notify_demand(_), do: :ok
    def status(_), do: :unavailable
  end

  setup do
    boundary = start_supervised!({Agent, fn -> %{document: @empty, labels: Map.new(["1", "2", "3", "9"], &{&1, %{labels: ["agent:queued"]}}), save_result: :ok, marker_result: :ok} end})
    Process.register(boundary, Boundary)
    owner = self()
    settings = %Schema{build_queue: %Schema.BuildQueue{}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}

    pid =
      start_supervised!(
        {Server,
         name: nil,
         tracker: Boundary,
         store: Boundary,
         claim_probe: Boundary,
         settings: {:ok, settings},
         clock: fn -> 1_000 end,
         schedule: fn target, message, _ ->
           send(owner, {:scheduled, target, message})
           make_ref()
         end,
         exchange: :absent_mutation_exchange}
      )

    assert_received {:scheduled, ^pid, {:reconcile, token}}
    send(pid, {:reconcile, token})
    assert GenServer.call(pid, :status) == :running
    %{server: pid}
  end

  test "daemon refuses caller workspace before touching server" do
    assert {:error, :agent_workspace} = MutationCLI.execute(verb: :add, ids: ["1"], caller_agent_workspace: "/caller", server: :missing)
    output = capture_io(fn -> assert Aiur.BuildQueueCLI.run(verb: :add, ids: ["1"], caller_agent_workspace: "/caller", error_fun: &IO.puts/1) == 64 end)
    assert output =~ "blocked in agent workspace"
    assert document() == @empty
  end

  test "add queues unobserved IDs pending while retaining partial successes", %{server: pid} do
    assert {:ok, [{"#1", :ok}]} = MutationCLI.execute(verb: :add, ids: ["1"], queue: "paseo", server: pid)
    Agent.update(Boundary, fn state -> Map.put(state, :observation_labels, Map.delete(state.labels, "9")) end)
    output = capture_io(fn -> assert Aiur.BuildQueueCLI.run(verb: :add, ids: ["1", "2", "9"], queue: "other", server: pid) == 1 end)
    assert output =~ "#1: already in queue paseo"
    assert output =~ "#2: ok"
    assert output =~ "#9: not yet observed (retry after next poll) for #9; queued pending"
    refute output =~ "#9: closed"
    assert Enum.map(document().items, & &1.issue_id) == ["1", "2", "9"]
    assert document().intents |> Enum.map(&{&1.issue_id, &1.action}) |> Enum.uniq() == [{"1", :mark}, {"2", :mark}, {"9", :mark}]
    assert Agent.get(Boundary, & &1.closure_reads) == ["9"]
  end

  test "same-command anchor add gets the same first-observation verdict in either order", %{server: pid} do
    # Regression guard: the CLI must send either order through the server's mutation gate.
    state = :sys.get_state(pid)
    :sys.replace_state(pid, &%{&1 | phase: :awaiting_first_observation})

    verdicts =
      for ids <- [["1", "2"], ["2", "1"]] do
        assert {:ok, results} = MutationCLI.execute(verb: :add, ids: ids, queue: "e2e", after: "9", server: pid)
        Enum.map(results, &elem(&1, 1))
      end

    assert verdicts == List.duplicate([{:error, :awaiting_first_observation}, {:error, :awaiting_first_observation}], 2)

    assert document() == @empty
    :sys.replace_state(pid, fn current -> %{current | phase: state.phase} end)
  end

  test "after anchor must be a member of the target queue unless added in this command", %{server: pid} do
    assert {:ok, [{"#2", {:error, :anchor_not_in_queue}}]} = MutationCLI.execute(verb: :add, ids: ["2"], queue: "e2e", after: "1", server: pid)
    assert document() == @empty

    assert {:ok, _} = MutationCLI.execute(verb: :add, ids: ["1", "2"], queue: "e2e", after: "1", server: pid)
    assert Enum.map(document().edges, &{&1.prerequisite, &1.dependent}) == [{"1", "2"}]
  end

  test "a batch crossing an already queued ID retains independent additions", %{server: pid} do
    run(pid, :add, ids: ["1"], queue: "paseo")
    output = capture_io(fn -> assert Aiur.BuildQueueCLI.run(verb: :add, ids: ["1", "2"], queue: "other", server: pid) == 1 end)
    assert output =~ "#1: already in queue paseo"
    assert output =~ "#2: ok"
    assert Enum.map(document().items, & &1.issue_id) == ["1", "2"]
  end

  test "same-command batch reports only the queued ID as the cause of atomic refusal", %{server: pid} do
    run(pid, :add, ids: ["1"], queue: "paseo")
    output = capture_io(fn -> assert Aiur.BuildQueueCLI.run(verb: :add, ids: ["1", "2"], queue: "other", after: "1", server: pid) == 1 end)
    assert output =~ "#1: already in queue paseo"
    assert output =~ "#2: not applied because another ID in this all-or-nothing batch was refused"
    assert Enum.map(document().items, & &1.issue_id) == ["1"]
  end

  test "add reports an unobserved but closed issue closed and does not queue it", %{server: pid} do
    Agent.update(Boundary, &Map.merge(&1, %{observation_labels: Map.delete(&1.labels, "9"), closures: %{"9" => {:ok, %{open?: false, state_reason: "completed"}}}}))
    output = capture_io(fn -> assert Aiur.BuildQueueCLI.run(verb: :add, ids: ["2", "9"], queue: "paseo", server: pid) == 1 end)
    assert output =~ "#2: ok"
    assert output =~ "#9: closed"
    refute output =~ "not yet observed"
    assert Enum.map(document().items, & &1.issue_id) == ["2"]
    refute Enum.any?(document().intents, &(&1.issue_id == "9"))
    assert Agent.get(Boundary, & &1.closure_reads) == ["9"]
  end

  test "add reads a cached closure without a tracker call", %{server: pid} do
    Agent.update(Boundary, &Map.put(&1, :observation_labels, Map.delete(&1.labels, "9")))
    :sys.replace_state(pid, &%{&1 | closure_cache: %{"9" => {:ok, %{open?: false, state_reason: "completed"}}}})
    assert {:ok, [{"#9", {:error, :closed}}]} = MutationCLI.execute(verb: :add, ids: ["9"], queue: "paseo", server: pid)
    assert document().items == []
    refute Map.has_key?(Agent.get(Boundary, & &1), :closure_reads)
  end

  test "batch insertion order survives marker-write failure after membership is saved", %{server: pid} do
    Agent.update(Boundary, &%{&1 | marker_result: {:error, :transient}})
    output = capture_io(fn -> assert Aiur.BuildQueueCLI.run(verb: :add, ids: ["1", "2"], at: 0, server: pid) == 1 end)
    assert output =~ "#1:"
    assert output =~ "#2:"
    assert output =~ "marker_write_failed"
    assert Enum.map(document().items, &{&1.issue_id, &1.position}) == [{"1", 0}, {"2", 1}]
  end

  test "rank at list creation persists in a batch and cannot silently reorder an existing set", %{server: pid} do
    run(pid, :add, ids: ["1"], queue: "first")
    run(pid, :add, ids: ["2", "3"], queue: "second", rank: 0)
    assert Enum.map(document().queues, &{&1.name, &1.rank}) == [{"second", 0}, {"first", 1}]
    assert Enum.map(document().items, & &1.issue_id) == ~w(1 2 3)
    assert {:ok, [{"#9", {:error, :rank_requires_new_queue}}]} = MutationCLI.execute(verb: :add, ids: ["9"], queue: "first", rank: 0, server: pid)
    assert {:ok, [{"first", {:error, :invalid_position}}]} = MutationCLI.execute(verb: :order, queue: "first", to: 5, server: pid)
  end

  test "positions edges reorder and remove traverse real persisted commands", %{server: pid} do
    run(pid, :add, ids: ["3", "1", "2"], after: "3")
    assert Enum.map(document().items, &{&1.issue_id, &1.position}) == [{"3", 0}, {"1", 1}, {"2", 2}]
    assert Enum.map(document().edges, &{&1.prerequisite, &1.dependent}) == [{"3", "1"}, {"3", "2"}]
    run(pid, :reorder, ids: ["2"], to: 0)
    assert Enum.map(document().items, & &1.issue_id) == ["2", "3", "1"]
    run(pid, :remove, ids: ["1", "3"])
    assert [%Model.Item{issue_id: "2", position: 0}] = document().items
  end

  test "item and named queue holds persist and release clears overrides and external holds", %{server: pid} do
    run(pid, :add, ids: ["1", "2"])
    run(pid, :hold, ids: ["1"])
    assert Enum.find(document().items, &(&1.issue_id == "1")).hold == :operator
    run(pid, :hold, queue: "default")
    assert hd(document().queues).held
    run(pid, :release, queue: "default")
    refute hd(document().queues).held
    assert Enum.all?(document().items, &is_nil(&1.hold))
    Agent.update(Boundary, fn state -> %{state | document: %{state.document | items: Enum.map(state.document.items, &%{&1 | hold: :external, override: :manual_promotion})}} end)
    # Restart from the persisted competing-writer state, rather than changing the server's internals.
    stop_supervised!(Server)
    settings = %Schema{build_queue: %Schema.BuildQueue{}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}

    restarted =
      start_supervised!(
        {Server,
         name: nil,
         tracker: Boundary,
         store: Boundary,
         claim_probe: Boundary,
         settings: {:ok, settings},
         clock: fn -> 1_000 end,
         schedule: fn _, _, _ -> make_ref() end,
         exchange: :absent_mutation_exchange}
      )

    run(restarted, :release, ids: ["1"])
    assert %{hold: nil, override: nil} = Enum.find(document().items, &(&1.issue_id == "1"))
    assert %{hold: :external, override: :manual_promotion} = Enum.find(document().items, &(&1.issue_id == "2"))
  end

  test "unobserved release results render a successful notice", %{server: pid} do
    run(pid, :add, ids: ["2"], queue: "default")
    Agent.update(Boundary, &Map.put(&1, :observation_unavailable?, true))

    output = capture_io(fn -> send(self(), {:release_result, Aiur.BuildQueueCLI.run(verb: :release, queue: "default", server: pid)}) end)
    assert_received {:release_result, result}

    assert result == 0, output
    assert output =~ "default: released; no observation for #2"
    assert Enum.all?(document().items, &is_nil(&1.hold))
  end

  test "a persisted hold prevents real promotion and publishes the dispatch hold", %{server: pid} do
    run(pid, :add, ids: ["1"])
    run(pid, :hold, ids: ["1"])
    reconcile(pid)
    assert Hints.held?("1")
    refute "agent:todo" in labels("1")
    run(pid, :release, ids: ["1"])
    reconcile(pid)
    assert "agent:todo" in labels("1")
    refute Hints.held?("1")
  end

  test "failed hold persistence refuses without changing membership", %{server: pid} do
    run(pid, :add, ids: ["1"])
    before = document()
    Agent.update(Boundary, &%{&1 | save_result: {:error, :disk_full}})
    assert {:ok, [{"#1", {:error, :disk_full}}]} = MutationCLI.execute(verb: :hold, ids: ["1"], server: pid)
    assert document() == before
    assert GenServer.call(pid, :status) == :store_unavailable
    assert {:error, :store_unavailable} = MutationCLI.execute(verb: :release, queue: "default", server: pid)
    output = capture_io(fn -> assert Aiur.BuildQueueCLI.run(verb: :hold, queue: "default", server: pid, error_fun: &IO.puts/1) == 1 end)
    assert output =~ "store unavailable"
    refute output =~ "not found"
  end

  test "an unreachable queue server never reports success" do
    for opts <- [[verb: :add, ids: ["1"]], [verb: :remove, ids: ["1"]], [verb: :hold, queue: "default"]] do
      output = capture_io(fn -> assert Aiur.BuildQueueCLI.run([{:server, :absent_queue_server}, {:error_fun, &IO.puts/1} | opts]) == 1 end)
      refute output =~ ": ok"
    end
  end

  test "invalid direct RPC arguments cannot mutate", %{server: pid} do
    for opts <- [
          [verb: :add, ids: ["1", "1"]],
          [verb: :hold, ids: ["1"], queue: "default"],
          [verb: :reorder, ids: ["1"], to: -1],
          [verb: :add, ids: ["1"], build_order: 9],
          [verb: :add, ids: ["1"], after: "1"],
          [verb: :remove, ids: ["1"], at: 0]
        ] do
      assert {:error, :invalid_arguments} = MutationCLI.execute(Keyword.put(opts, :server, pid))
    end

    assert document() == @empty
  end

  test "start-on add and set persist overrides and default without silent replacement", %{server: pid} do
    run(pid, :add, ids: ["1"], queue: "wave", start_on: "pr_ci_green")
    assert hd(document().queues).start_trigger == :pr_ci_green
    assert {:ok, [{"#2", {:error, :trigger_mismatch}}]} = MutationCLI.execute(verb: :add, ids: ["2"], queue: "wave", start_on: "pr_opened", server: pid)
    assert Enum.map(document().items, & &1.issue_id) == ["1"]
    run(pid, :set, queue: "wave", start_on: "pr_opened")
    assert hd(document().queues).start_trigger == :pr_opened
    assert hd(document().queues).generation == 1
    assert hd(Aiur.BuildQueue.show(pid).queues).start_trigger_override == :pr_opened
    run(pid, :set, queue: "wave", start_on: "default")
    assert hd(document().queues).start_trigger == nil
    assert hd(document().queues).generation == 2
    assert hd(Aiur.BuildQueue.show(pid).queues).start_trigger == :pr_merged
    assert {:ok, [{"missing", {:error, :not_found}}]} = MutationCLI.execute(verb: :set, queue: "missing", start_on: "pr_opened", server: pid)
  end

  test "optimistic add promotes through real reconciliation", %{server: pid} do
    Agent.update(Boundary, &%{&1 | labels: Map.put(&1.labels, "2", %{labels: ["agent:ci-wait"]})})
    run(pid, :add, ids: ["2"], start_on: "pr_opened")
    run(pid, :add, ids: ["1"], after: "2", start_on: "pr_opened")
    reconcile(pid)
    assert "agent:todo" in labels("1")
    assert Enum.find(document().items, &(&1.issue_id == "1")).promoted_at != nil
    assert Enum.find(hd(Aiur.BuildQueue.show(pid).queues).items, &(&1.number == 1)).state == :ready
  end

  test "a merged local prerequisite cannot bypass another native blocker", %{server: pid} do
    Agent.update(Boundary, &Map.merge(&1, %{dependencies: %{"1" => ["3"]}, prs: %{"2" => %{merged?: true, state: :closed}}}))
    run(pid, :add, ids: ["2"])
    run(pid, :add, ids: ["1"], after: "2")
    reconcile(pid)
    refute "agent:todo" in labels("1")
    item = Enum.find(hd(Aiur.BuildQueue.show(pid).queues).items, &(&1.number == 1))
    assert item.state == :waiting
    assert Enum.any?(:sys.get_state(pid).planned_edges, &(&1.prerequisite == "3" and &1.dependent == "1"))
  end

  test "a merge arriving during reconciliation cannot change unchecked native eligibility", %{server: pid} do
    merged = %{merged?: true, state: :closed}
    Agent.update(Boundary, &Map.merge(&1, %{dependencies: %{"1" => ["3"]}, prs: %{"2" => [nil, merged, merged]}}))
    run(pid, :add, ids: ["2"])
    run(pid, :add, ids: ["1"], after: "2")
    reconcile(pid)
    refute "agent:todo" in labels("1")
    # The merge remains for the next pass, when native prerequisites will be checked.
    assert Agent.get(Boundary, & &1.prs["2"]) == [merged, merged]
    assert :ok = GenServer.call(pid, :reconcile_now)
    reconcile(pid)
    refute "agent:todo" in labels("1")
    assert Enum.find(:sys.get_state(pid).projections, &(&1.issue_id == "1")).verdict == :waiting
    assert Enum.any?(:sys.get_state(pid).planned_edges, &(&1.prerequisite == "3" and &1.dependent == "1"))
  end

  test "invalid start-on exits 64 with allowed values before any mutation", %{server: pid} do
    before = document()
    output = capture_io(fn -> assert MutationCLI.run(verb: :add, ids: ["1"], start_on: "soon", server: pid, error_fun: &IO.puts/1) == 64 end)
    for trigger <- Aiur.StartTrigger.triggers(), do: assert(output =~ Atom.to_string(trigger))
    assert {:error, :invalid_start_trigger} = GenServer.call(pid, {:mutate, {:set_trigger, "wave", :soon}})
    assert {:error, :invalid_start_trigger} = GenServer.call(pid, {:mutate, {:add, ["2"], [queue: "wave", start_trigger: :soon]}})
    assert document() == before
    assert {:error, :invalid_arguments} = MutationCLI.execute(verb: :remove, ids: ["1"], start_on: "pr_opened", server: pid)
    assert {:error, :invalid_arguments} = MutationCLI.execute(verb: :set, queue: "wave", server: pid)
  end

  defp reconcile(pid) do
    assert_received {:scheduled, ^pid, {:reconcile, token}}
    send(pid, {:reconcile, token})
    GenServer.call(pid, :status)
  end

  defp labels(id), do: Agent.get(Boundary, & &1.labels[id].labels)

  defp run(pid, verb, opts) do
    output = capture_io(fn -> send(self(), {:run_result, Aiur.BuildQueueCLI.run(Keyword.merge(opts, verb: verb, server: pid))}) end)
    assert_received {:run_result, result}
    assert result == 0, output
    output
  end

  defp document, do: Agent.get(Boundary, & &1.document)
end
