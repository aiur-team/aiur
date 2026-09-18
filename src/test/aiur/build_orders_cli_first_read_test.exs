defmodule Aiur.BuildOrdersCLIFirstReadTest do
  # #2695: after a daemon restart, `aiur build-orders <root> --json` reported
  # `provider_unavailable` for minutes and only converged once a dashboard
  # LiveView opened the root. Registering demand buys nothing, and a catalog
  # completion only re-reads roots a live page is watching, so a terminal read —
  # whose RPC process is gone by the time the catalog lands — never bought the
  # first selected-root read. These tests drive the real projection with no
  # LiveView anywhere.
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{Catalog, Member, ProviderHealth, ProviderResult, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.{BuildOrdersCLI, TrackerIdentity}

  @repository {"owner", "repo"}
  @now ~U[2026-07-15 12:00:00Z]

  # The CLI's `{module, context}` source form, bound to one projection pid.
  defmodule ProjectionSource do
    alias Aiur.BuildOrder.GraphProjection

    def catalog(projection), do: GraphProjection.catalog(projection)
    def demand(projection, identity), do: GraphProjection.demand(projection, identity)
    def refresh(projection, identity), do: GraphProjection.refresh(projection, identity)
    def selected(projection, identity), do: GraphProjection.selected(projection, identity)
    def load_runtime_sources(_projection), do: %{execution: %{running: [], retrying: [], idle: []}, activity: %{generation: 1, entries: [], diagnostics: %{}}}
  end

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  test "a CLI single-root read on a fresh projection buys the first graph read and converges to ready with no LiveView" do
    root_identity = identity(1, "I1")
    {:ok, projection} = start_projection()

    finish(await_reader(:catalog), {:ok, ProviderResult.complete(Catalog.new([root(root_identity)], healthy()))})
    await_catalog(projection)

    # First read: the fetch is in flight, and the reply says so rather than
    # claiming the provider is unavailable.
    first = cli_read(projection, "1")
    reader = await_reader({:selected, root_identity})

    assert first["data"]["graph"]["status"] == "loading"
    assert first["sources"]["planning_graph"]["state"] == "loading"
    assert first["sources"]["planning_graph"]["reasons"] == []
    refute Enum.any?(first["data"]["graph"]["diagnostics"], &(&1["code"] == "provider_unavailable"))

    # A second read while the fetch is still running coalesces onto it and stays
    # truthful.
    assert cli_read(projection, "1")["data"]["graph"]["status"] == "loading"
    refute_receive {:reader_started, {:selected, ^root_identity}, _reader}, 100

    # The CLI process that asked is gone; the read still lands and the next CLI
    # read reports the graph.
    finish(reader, {:ok, ProviderResult.complete(selected(root_identity))})
    ready = await_ready(projection, "1")

    assert ready["sources"]["planning_graph"]["state"] == "available"
    assert Enum.map(ready["data"]["graph"]["members"], & &1["id"]) == ["2"]
  end

  test "a first read that fails is reported as unavailable, not loading" do
    root_identity = identity(1, "I1")
    {:ok, projection} = start_projection()

    finish(await_reader(:catalog), {:ok, ProviderResult.complete(Catalog.new([root(root_identity)], healthy()))})
    await_catalog(projection)

    assert cli_read(projection, "1")["data"]["graph"]["status"] == "loading"
    finish(await_reader({:selected, root_identity}), {:error, :transport})

    failed = await_status(projection, "1", "provider_unavailable")
    assert failed["sources"]["planning_graph"]["state"] == "unavailable"
  end

  # Each read runs in its own short-lived process, as the RPC behind the CLI
  # does, so no demander outlives the command.
  defp cli_read(projection, root) do
    task = Task.async(fn -> BuildOrdersCLI.build(root: root, source: {ProjectionSource, projection}, now: @now) end)
    assert {:ok, envelope} = Task.await(task)
    envelope
  end

  defp await_ready(projection, root), do: await_status(projection, root, "ready")

  defp await_status(projection, root, status, attempts \\ 100) do
    envelope = cli_read(projection, root)

    cond do
      envelope["data"]["graph"]["status"] == status ->
        envelope

      attempts > 0 ->
        Process.sleep(20)
        await_status(projection, root, status, attempts - 1)

      true ->
        flunk("graph status stayed #{envelope["data"]["graph"]["status"]}, expected #{status}")
    end
  end

  defp await_catalog(projection, attempts \\ 100) do
    cond do
      match?(%{data: %Catalog{}}, GraphProjection.catalog(projection)) ->
        :ok

      attempts > 0 ->
        Process.sleep(20)
        await_catalog(projection, attempts - 1)

      true ->
        flunk("catalog never loaded")
    end
  end

  defp start_projection do
    parent = self()
    task_supervisor = start_supervised!(%{id: make_ref(), start: {Task.Supervisor, :start_link, [[]]}})

    authority = %{
      repository: @repository,
      generation: 1,
      root_limit: 100,
      page_budget: 4,
      call_budget: 4,
      options: [catalog_refresh_ms: 60_000, refresh_timeout_ms: 30_000, max_selected_roots: 4, max_inflight: 4]
    }

    GraphProjection.start_link(
      name: nil,
      task_supervisor: task_supervisor,
      authority_snapshot: fn -> authority end,
      configuration_subscriber: fn _pid -> :ok end,
      reconciliation_fun: fn _opts -> :ok end,
      catalog_reader: fn _reader_opts -> blocking_read(parent, :catalog) end,
      selected_reader: fn identity, _reader_opts -> blocking_read(parent, {:selected, identity}) end,
      now: fn -> @now end,
      clock_ms: fn -> 0 end,
      catalog_refresh_ms: 60_000,
      refresh_timeout_ms: 30_000,
      max_selected_roots: 4,
      max_inflight: 4
    )
  end

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

  defp healthy, do: ProviderHealth.new(1, :healthy, true)

  defp selected(root_identity) do
    member =
      Member.new(%{
        identity: identity(2, "I2"),
        title: "Ticket 2",
        url: "https://github.com/owner/repo/issues/2",
        state: :open,
        labels: ["complexity:3", "phase:1", "build-lane:runtime"],
        updated_at: @now,
        dependencies: []
      })

    SelectedRoot.new(root(root_identity), [member], healthy())
  end

  defp root(identity) do
    RootSummary.new(%{
      identity: identity,
      title: "Build Order #{identity.identifier}",
      url: "https://github.com/owner/repo/issues/#{identity.identifier}",
      state: "OPEN",
      labels: ["build-order"],
      member_count: 1,
      updated_at: @now
    })
  end

  defp identity(number, provider_id) do
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => provider_id, "number" => number}, @repository, @repository)
    identity
  end
end
