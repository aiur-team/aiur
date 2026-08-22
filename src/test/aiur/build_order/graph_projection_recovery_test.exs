defmodule Aiur.BuildOrder.GraphProjectionRecoveryTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{Catalog, ProviderHealth, ProviderResult, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.{Policy, Snapshot}
  alias Aiur.TrackerIdentity

  @now ~U[2026-07-15 12:00:00Z]
  @recovering_supervisor Aiur.BuildOrder.GraphProjectionRecoveryTest.TaskSupervisor

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  test "invalid configuration starts no work and cannot accept an old-authority result" do
    repository = repository()
    authority = supervised_agent(%{repository: :invalid})
    authority_snapshot = fn -> Agent.get(authority, & &1) end
    {:ok, projection} = start_projection(repository, authority_snapshot: authority_snapshot)

    assert %{catalog: %{health: %{failure: :configuration}}, inflight_by_ref: inflight} =
             :sys.get_state(projection)

    assert inflight == %{}
    refute_receive {:reader_started, :catalog, _reader}

    Agent.update(authority, fn _ -> authority(repository, 1) end)
    send(projection, {:workflow_config_updated, 1})
    _old_reader = await_reader(:catalog)
    [{old_ref, _inflight}] = Map.to_list(:sys.get_state(projection).inflight_by_ref)

    Agent.update(authority, fn _ -> %{repository: :invalid} end)
    send(projection, {:workflow_config_updated, 2})

    assert %{catalog: %{health: %{failure: :configuration}}, inflight_by_ref: %{}} =
             :sys.get_state(projection)

    stale = catalog([root(identity(1, "I1", repository), repository)])
    send(projection, {old_ref, {:ok, ProviderResult.complete(stale)}})
    :sys.get_state(projection)

    refute_receive {:projection_event, {:graph_projection_generation, %Snapshot{}}}

    assert %Snapshot{data: nil, generation: :unknown, health: %{failure: :configuration}} =
             GraphProjection.catalog(projection)

    refute_receive {:reader_started, :catalog, _reader}
  end

  test "task completion self-reconciles and fences a newer same-repository generation" do
    repository = repository()
    authority = supervised_agent(authority(repository, 1))
    authority_snapshot = fn -> Agent.get(authority, & &1) end
    {:ok, projection} = start_projection(repository, authority_snapshot: authority_snapshot)
    old_reader = await_reader(:catalog)

    Agent.update(authority, fn _ -> authority(repository, 2, catalog_refresh_ms: 120_000) end)
    candidate = catalog([root(identity(1, "I1", repository), repository)])
    finish(old_reader, {:ok, ProviderResult.complete(candidate)})

    replacement_reader = await_reader(:catalog)
    refute_receive {:projection_event, {:graph_projection_generation, %Snapshot{}}}

    assert %{active_configuration_generation: 2, inflight_by_ref: inflight} =
             :sys.get_state(projection)

    assert map_size(inflight) == 1
    finish(replacement_reader, {:ok, ProviderResult.complete(candidate)})

    assert_receive {
                     :projection_event,
                     {:graph_projection_generation, %Snapshot{data: ^candidate, generation: 1}}
                   },
                   2_000
  end

  test "cold selected retry survives release and recovers on an explicit refresh" do
    repository = repository()
    identity = identity(1, "I1", repository)
    clock = supervised_agent(%{now: @now, ms: 0})
    {:ok, projection} = start_projection(repository, clock: clock)

    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(identity, repository)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, identity)
    :ok = GraphProjection.refresh(projection, identity)
    failed_reader = await_reader({:selected, identity})

    finish(
      failed_reader,
      {:error, ProviderResult.failed(:rate_limited, rate_limit: %{retry_after: 12})}
    )

    scope = {:selected, identity}
    failure = :rate_limited

    assert_receive {
                     :projection_event,
                     {:graph_projection_health, %Snapshot{scope: ^scope, health: %{failure: ^failure}}}
                   },
                   2_000

    key = Policy.root_key(identity)
    failed = :sys.get_state(projection).selected[key]
    assert DateTime.diff(failed.health.next_retry_at, @now, :second) == 12
    assert is_reference(failed.timer)

    assert :ok = GraphProjection.release(projection, identity)
    released = :sys.get_state(projection).selected[key]
    assert released.timer == nil
    assert released.health.next_retry_at == failed.health.next_retry_at

    assert {:ok, %Snapshot{health: %{next_retry_at: next_retry_at}}} =
             GraphProjection.demand(projection, identity)

    assert next_retry_at == failed.health.next_retry_at
    rearmed = :sys.get_state(projection).selected[key]
    assert rearmed.timer == nil
    refute_receive {:reader_started, {:selected, ^identity}, _reader}

    Agent.update(clock, fn _ -> %{now: DateTime.add(@now, 12, :second), ms: 12_000} end)
    :ok = GraphProjection.refresh(projection, identity)
    recovery_reader = await_reader({:selected, identity})
    recovered = selected(identity, repository)
    finish(recovery_reader, {:ok, ProviderResult.complete(recovered)})

    assert_receive {
                     :projection_event,
                     {:graph_projection_generation, %Snapshot{scope: {:selected, ^identity}, data: ^recovered}}
                   },
                   2_000
  end

  # A selected root has no cadence any more, so `reschedule_active_scopes/1` no
  # longer re-arms one — and it runs on almost every message after cancelling
  # every timer. A failed read's backoff timer therefore has to be restored
  # explicitly, or the very next unrelated message silently throws away the only
  # thing that would ever read that root again.
  test "a failed selected read keeps its retry timer across unrelated messages" do
    repository = repository()
    identity = identity(1, "I1", repository)
    clock = supervised_agent(%{now: @now, ms: 0})
    {:ok, projection} = start_projection(repository, clock: clock)

    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(identity, repository)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, identity)
    :ok = GraphProjection.refresh(projection, identity)

    finish(
      await_reader({:selected, identity}),
      {:error, ProviderResult.failed(:rate_limited, rate_limit: %{retry_after: 12})}
    )

    scope = {:selected, identity}
    failure = :rate_limited

    assert_receive {
                     :projection_event,
                     {:graph_projection_health, %Snapshot{scope: ^scope, health: %{failure: ^failure}}}
                   },
                   2_000

    key = Policy.root_key(identity)
    assert is_reference(:sys.get_state(projection).selected[key].timer)

    # Any message at all reconciles, and reconciling cancels every timer. Three
    # of them, so a single lucky ordering cannot make this pass.
    for _ <- 1..3 do
      assert %Snapshot{} = GraphProjection.catalog(projection)
    end

    retained = :sys.get_state(projection).selected[key]
    assert is_reference(retained.timer)
    assert DateTime.diff(retained.health.next_retry_at, @now, :second) == 12

    # And it is still a retry, not a cadence: nothing is read before it is due.
    refute_receive {:reader_started, {:selected, ^identity}, _reader}, 200
  end

  test "missing task supervisor reports bounded failure and recovers when the supervisor returns" do
    repository = repository()
    refute Process.whereis(@recovering_supervisor)
    clock = supervised_agent(%{now: @now, ms: 0})

    {:ok, projection} =
      start_projection(repository,
        clock: clock,
        task_supervisor: @recovering_supervisor
      )

    assert_receive {
                     :projection_event,
                     {:graph_projection_health, %Snapshot{scope: :catalog, data: nil, health: %{failure: :transport}}}
                   },
                   2_000

    failed = :sys.get_state(projection)
    assert failed.inflight_by_ref == %{}
    assert failed.pending == MapSet.new()
    assert is_reference(failed.catalog.timer)
    refute_receive {:reader_started, :catalog, _reader}

    Agent.update(clock, fn _ -> %{now: DateTime.add(@now, 1, :second), ms: 1_000} end)

    assert %Snapshot{data: nil, health: %{failure: :transport}} =
             GraphProjection.catalog(projection)

    rescheduled = :sys.get_state(projection)
    assert is_reference(rescheduled.catalog.timer)

    start_supervised!({Task.Supervisor, name: @recovering_supervisor})
    fire_timer(projection, rescheduled.catalog, :catalog)
    reader = await_reader(:catalog)
    candidate = catalog([])
    finish(reader, {:ok, ProviderResult.complete(candidate)})

    assert_receive {
                     :projection_event,
                     {:graph_projection_generation, %Snapshot{scope: :catalog, data: ^candidate}}
                   },
                   2_000

    assert map_size(:sys.get_state(projection).inflight_by_ref) == 0
    refute_receive {:reader_started, :catalog, _reader}
  end

  test "max inflight coalesces pending selected work and admits it after capacity" do
    repository = repository()
    first = identity(1, "I1", repository)
    second = identity(2, "I2", repository)
    {:ok, projection} = start_projection(repository, max_inflight: 1)

    roots = catalog([root(first, repository), root(second, repository)])
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(roots)})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    assert {:ok, %Snapshot{}} = GraphProjection.demand(projection, first)
    :ok = GraphProjection.refresh(projection, first)
    first_reader = await_reader({:selected, first})
    assert {:ok, %Snapshot{}} = GraphProjection.demand(projection, second)
    :ok = GraphProjection.refresh(projection, second)

    for _ <- 1..3 do
      :ok = GraphProjection.refresh(projection, second)
    end

    refute_receive {:reader_started, {:selected, ^second}, _reader}
    state = :sys.get_state(projection)
    assert map_size(state.inflight_by_ref) == 1
    assert state.pending == MapSet.new([{:selected, second}])

    first_result = selected(first, repository)
    finish(first_reader, {:ok, ProviderResult.complete(first_result)})
    second_reader = await_reader({:selected, second})

    state = :sys.get_state(projection)
    assert map_size(state.inflight_by_ref) == 1
    assert state.pending == MapSet.new()

    second_result = selected(second, repository)
    finish(second_reader, {:ok, ProviderResult.complete(second_result)})

    assert_receive {
                     :projection_event,
                     {:graph_projection_generation, %Snapshot{scope: {:selected, ^first}, data: ^first_result}}
                   },
                   2_000

    assert_receive {
                     :projection_event,
                     {:graph_projection_generation, %Snapshot{scope: {:selected, ^second}, data: ^second_result}}
                   },
                   2_000
  end

  defp start_projection(repository, opts) do
    parent = self()
    authority_snapshot = Keyword.get(opts, :authority_snapshot, fn -> authority(repository, 1, opts) end)
    task_supervisor = Keyword.get_lazy(opts, :task_supervisor, &task_supervisor/0)
    clock = Keyword.get(opts, :clock)

    start_supervised(%{
      id: make_ref(),
      start:
        {GraphProjection, :start_link,
         [
           [
             name: nil,
             task_supervisor: task_supervisor,
             authority_snapshot: authority_snapshot,
             configuration_subscriber: fn _pid -> :ok end,
             reconciliation_fun: fn _opts -> :ok end,
             catalog_reader: blocking_reader(parent, :catalog),
             selected_reader: fn identity, _reader_opts -> blocking_read(parent, {:selected, identity}) end,
             now: now_fun(clock),
             clock_ms: clock_ms_fun(clock),
             after_broadcast: fn event -> send(parent, {:projection_event, event}) end
           ]
         ]}
    })
  end

  defp task_supervisor do
    start_supervised!(%{id: make_ref(), start: {Task.Supervisor, :start_link, [[]]}})
  end

  defp supervised_agent(initial) do
    start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> initial end]}})
  end

  defp now_fun(nil), do: fn -> @now end
  defp now_fun(clock), do: fn -> Agent.get(clock, & &1.now) end
  defp clock_ms_fun(nil), do: fn -> 0 end
  defp clock_ms_fun(clock), do: fn -> Agent.get(clock, & &1.ms) end

  defp fire_timer(projection, entry, scope) do
    Process.cancel_timer(entry.timer)
    send(projection, {:graph_projection_due, scope, entry.timer_token})
  end

  defp blocking_reader(parent, scope), do: fn _reader_opts -> blocking_read(parent, scope) end

  defp blocking_read(parent, scope) do
    send(parent, {:reader_started, scope, self()})
    receive do: ({:finish, result} -> result)
  end

  defp await_reader(scope) do
    assert_receive {:reader_started, ^scope, reader}, 2_000
    reader
  end

  defp finish(reader, result), do: send(reader, {:finish, result})

  defp authority(repository, generation, opts \\ []) do
    %{
      repository: repository,
      generation: generation,
      root_limit: 100,
      page_budget: 4,
      call_budget: 4,
      options: [
        catalog_refresh_ms: Keyword.get(opts, :catalog_refresh_ms, 60_000),
        refresh_timeout_ms: 30_000,
        max_selected_roots: 4,
        max_inflight: Keyword.get(opts, :max_inflight, 4)
      ]
    }
  end

  defp repository do
    {"recovery-owner", "repo-#{System.unique_integer([:positive])}"}
  end

  defp catalog(roots), do: Catalog.new(roots, ProviderHealth.new(1, :healthy, true))
  defp selected(identity, repository), do: SelectedRoot.new(root(identity, repository), [], ProviderHealth.new(1, :healthy, true))

  defp root(identity, {owner, repository}) do
    RootSummary.new(%{
      identity: identity,
      title: "Build Order #{identity.identifier}",
      url: "https://github.com/#{owner}/#{repository}/issues/#{identity.identifier}",
      state: "OPEN"
    })
  end

  defp identity(number, provider_id, repository) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => provider_id, "number" => number},
        repository,
        repository
      )

    identity
  end
end
