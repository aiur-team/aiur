defmodule Aiur.BuildOrder.GraphProjectionStructuralTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{Catalog, Diagnostic, ProviderHealth, ProviderResult, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity

  @repository {"structural-owner", "structural-repo"}
  @now ~U[2026-07-15 12:00:00Z]

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  test "one malformed catalog root remains isolated from valid siblings" do
    valid = root(identity(1, "I1"))

    malformed =
      RootSummary.new(%{
        identity: identity(2, "I2"),
        title: "Nested root",
        url: issue_url(2),
        parent_identity: valid.identity,
        state: "OPEN"
      })

    candidate = catalog([malformed, valid])
    projection = start_projection()
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(candidate)})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{} = published}}, 2_000
    assert published.scope == :catalog
    assert published.data == candidate
    assert published.health.state == :healthy

    snapshot = GraphProjection.catalog(projection)
    assert snapshot.data.entries == [malformed, valid]
    assert {:structurally_invalid, ^malformed} = Catalog.select(snapshot.data, malformed.identity)
    assert {:ok, ^valid} = Catalog.select(snapshot.data, valid.identity)
  end

  test "cold selected structural failure is distinct from selected unavailability" do
    identity = identity(1, "I1")
    projection = start_projection()
    publish_catalog(projection, [root(identity)])

    assert {:ok,
            %Snapshot{
              generation: :unknown,
              data: nil,
              health: %{state: :unavailable, failure: nil}
            }} = GraphProjection.selected(projection, identity)

    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, identity)
    reader = await_reader({:selected, identity})
    malformed = malformed_selected(identity)
    finish(reader, {:ok, ProviderResult.complete(malformed)})

    assert_receive {
                     :projection_event,
                     {:graph_projection_health,
                      %Snapshot{
                        scope: {:selected, ^identity},
                        generation: :unknown,
                        data: nil,
                        health: %{state: :structurally_invalid, failure: :structurally_invalid}
                      }}
                   },
                   2_000

    assert {:ok,
            %Snapshot{
              generation: :unknown,
              data: nil,
              health: %{state: :structurally_invalid, failure: :structurally_invalid}
            }} = GraphProjection.selected(projection, identity)

    assert :ok = GraphProjection.release(projection, identity)
  end

  test "cold selected read failure retains its concrete provider fault" do
    identity = identity(1, "I1")
    projection = start_projection()
    publish_catalog(projection, [root(identity)])

    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, identity)

    result =
      ProviderResult.failed(:missing_github_token,
        diagnostics: [Diagnostic.new(:missing_github_token)]
      )

    finish(await_reader({:selected, identity}), {:error, result})

    assert_receive {
                     :projection_event,
                     {:graph_projection_health,
                      %Snapshot{
                        scope: {:selected, ^identity},
                        data: nil,
                        health: %{state: :unavailable, failure: :missing_github_token}
                      }}
                   },
                   2_000

    assert {:ok,
            %Snapshot{
              data: nil,
              health: %{state: :unavailable, failure: :missing_github_token}
            }} = GraphProjection.selected(projection, identity)

    assert :ok = GraphProjection.release(projection, identity)
  end

  test "selected structural failure retains prior LKG as stale degraded data" do
    identity = identity(1, "I1")
    clock = supervised_agent(%{now: @now, ms: 0})
    projection = start_projection(clock: clock, demand_refresh_ms: 5_000)
    publish_catalog(projection, [root(identity)])

    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, identity)
    first_reader = await_reader({:selected, identity})
    last_known_good = selected(identity)
    finish(first_reader, {:ok, ProviderResult.complete(last_known_good)})

    assert_receive {
                     :projection_event,
                     {:graph_projection_generation,
                      %Snapshot{
                        scope: {:selected, ^identity},
                        generation: generation,
                        data: ^last_known_good,
                        health: %{state: :healthy}
                      }}
                   },
                   2_000

    Agent.update(clock, fn _ ->
      %{now: DateTime.add(@now, 5_001, :millisecond), ms: 5_001}
    end)

    assert {:ok, %Snapshot{data: ^last_known_good}} = GraphProjection.demand(projection, identity)
    refresh_reader = await_reader({:selected, identity})
    finish(refresh_reader, {:ok, ProviderResult.complete(malformed_selected(identity))})

    assert_receive {
                     :projection_event,
                     {:graph_projection_health,
                      %Snapshot{
                        scope: {:selected, ^identity},
                        generation: ^generation,
                        data: ^last_known_good,
                        health: %{state: :stale, failure: :structurally_invalid}
                      }}
                   },
                   2_000

    assert {:ok,
            %Snapshot{
              generation: ^generation,
              data: ^last_known_good,
              health: %{state: :stale, failure: :structurally_invalid}
            }} = GraphProjection.selected(projection, identity)

    assert :ok = GraphProjection.release(projection, identity)
  end

  defp start_projection(opts \\ []) do
    parent = self()
    clock = Keyword.get(opts, :clock)
    demand_refresh_ms = Keyword.get(opts, :demand_refresh_ms, 5_000)

    task_supervisor =
      start_supervised!(%{
        id: make_ref(),
        start: {Task.Supervisor, :start_link, [[]]}
      })

    start_supervised!(%{
      id: make_ref(),
      start:
        {GraphProjection, :start_link,
         [
           [
             name: nil,
             task_supervisor: task_supervisor,
             authority_snapshot: fn -> authority(demand_refresh_ms) end,
             configuration_subscriber: fn _pid -> :ok end,
             catalog_reader: blocking_reader(parent, :catalog),
             selected_reader: fn identity, _reader_opts ->
               blocking_read(parent, {:selected, identity})
             end,
             now: now_fun(clock),
             clock_ms: clock_ms_fun(clock),
             after_broadcast: fn event -> send(parent, {:projection_event, event}) end
           ]
         ]}
    })
  end

  defp publish_catalog(projection, roots) do
    candidate = catalog(roots)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(candidate)})

    assert_receive {
                     :projection_event,
                     {:graph_projection_generation, %Snapshot{scope: :catalog, data: ^candidate}}
                   },
                   2_000

    assert GraphProjection.catalog(projection).data == candidate
  end

  defp blocking_reader(parent, scope), do: fn _reader_opts -> blocking_read(parent, scope) end

  defp blocking_read(parent, scope) do
    send(parent, {:reader_started, scope, self()})

    receive do
      {:finish, result} -> result
    end
  end

  defp await_reader(scope) do
    assert_receive {:reader_started, ^scope, reader}, 2_000
    reader
  end

  defp finish(reader, result), do: send(reader, {:finish, result})

  defp authority(demand_refresh_ms) do
    %{
      repository: @repository,
      generation: 1,
      root_limit: 100,
      page_budget: 4,
      call_budget: 4,
      options: [
        catalog_refresh_ms: 60_000,
        selected_refresh_ms: 60_000,
        demand_refresh_ms: demand_refresh_ms,
        refresh_timeout_ms: 30_000,
        max_selected_roots: 4,
        max_inflight: 4
      ]
    }
  end

  defp now_fun(nil), do: fn -> @now end
  defp now_fun(clock), do: fn -> Agent.get(clock, & &1.now) end
  defp clock_ms_fun(nil), do: fn -> 0 end
  defp clock_ms_fun(clock), do: fn -> Agent.get(clock, & &1.ms) end

  defp supervised_agent(initial) do
    start_supervised!(%{
      id: make_ref(),
      start: {Agent, :start_link, [fn -> initial end]}
    })
  end

  defp catalog(roots), do: Catalog.new(roots, ProviderHealth.new(1, :healthy, true))

  defp selected(identity) do
    SelectedRoot.new(root(identity), [], ProviderHealth.new(1, :healthy, true))
  end

  defp malformed_selected(identity) do
    SelectedRoot.new(root(identity), [:malformed], ProviderHealth.new(1, :healthy, true))
  end

  defp root(identity) do
    RootSummary.new(%{
      identity: identity,
      title: "Build Order #{identity.identifier}",
      url: issue_url(identity.identifier),
      state: "OPEN"
    })
  end

  defp identity(number, provider_id) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => provider_id, "number" => number},
        @repository,
        @repository
      )

    identity
  end

  defp issue_url(number) do
    {owner, repository} = @repository
    "https://github.com/#{owner}/#{repository}/issues/#{number}"
  end
end
