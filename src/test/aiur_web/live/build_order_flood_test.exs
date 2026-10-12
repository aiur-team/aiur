defmodule AiurWeb.BuildOrderFloodTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  alias Aiur.{AgentPubSub, TrackerIdentity}
  alias Aiur.BuildOrder.{Catalog, ProviderHealth, RootSummary}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias AiurWeb.Endpoint
  @endpoint Endpoint

  defmodule Source do
    def subscribe_catalog(_server), do: :ok
    def subscribe_sources(_server), do: AgentPubSub.subscribe_running()
    def catalog(server), do: Agent.get(server, & &1.catalog)

    def load_sources(server) do
      Agent.get_and_update(server, fn state ->
        sources = %{execution: %{running: [], retrying: [], idle: []}, activity: %{generation: state.generation, entries: []}}
        {sources, %{state | reads: state.reads + 1}}
      end)
    end
  end

  setup do
    health = %ProviderHealth{state: :healthy, generation: 1}

    roots =
      for number <- 1..100 do
        {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "NODE-#{number}", "database_id" => number, "number" => number}, {"owner", "repo"}, {"owner", "repo"})
        RootSummary.new(%{identity: identity, title: "Flood root #{number}", state: "OPEN", url: "https://github.com/owner/repo/issues/#{number}"})
      end

    catalog = %Snapshot{scope: :catalog, repository: {"owner", "repo"}, authority_epoch: 1, generation: 1, data: Catalog.new(roots, health), health: health}
    source = start_supervised!({Agent, fn -> %{catalog: catalog, reads: 0, generation: 1} end})
    previous_source = Application.get_env(:aiur, :build_order_data_source)
    previous_endpoint = Application.get_env(:aiur, Endpoint)
    Application.put_env(:aiur, :build_order_data_source, {Source, source})
    Application.put_env(:aiur, Endpoint, Keyword.merge(previous_endpoint || [], server: false, secret_key_base: String.duplicate("s", 64), dashboard_writable: false, dashboard_auth_required: false))
    Aiur.TestSupport.start_owned_endpoint!()

    on_exit(fn ->
      restore(:build_order_data_source, previous_source)
      restore(Endpoint, previous_endpoint)
    end)

    %{source: source}
  end

  test "thousands of broadcasts bound reads, renders, memory and a stalled LiveView mailbox", %{source: source} do
    {:ok, view, _} = live(build_conn(), "/build-orders")
    render_async(view)
    assert render(view) =~ "Flood root 100"
    baseline_reads = Agent.get(source, & &1.reads)
    counter = :atomics.new(1, [])
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:phoenix, :live_view, :render, :stop],
        fn _, _, _, {pid, counter} ->
          if self() == pid, do: :atomics.add(counter, 1, 1)
        end,
        {view.pid, counter}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    started_at = System.monotonic_time(:millisecond)
    Agent.update(source, &%{&1 | generation: 2})
    # Spread the flood across intervals so a fast per-event reader cannot hide behind single-flight.
    for _ <- 1..40 do
      for _ <- 1..125, do: AgentPubSub.broadcast_running_change([])
      Process.sleep(25)
    end

    Process.sleep(650)
    render_async(view)
    reads = Agent.get(source, & &1.reads) - baseline_reads
    intervals = div(System.monotonic_time(:millisecond) - started_at, 500) + 1
    assert reads in 1..(intervals + 1)
    assert :atomics.get(counter, 1) <= 4 * intervals + 4
    assert :sys.get_state(view.pid).socket.assigns.sources.activity.generation == 2

    relay =
      :sys.get_state(view.pid).socket.private.lifecycle.handle_info
      |> Enum.map(& &1.id)
      |> Enum.find(fn pid -> is_pid(pid) and :running_changed in :sys.get_state(pid).events end)

    assert is_pid(relay)
    :ok = :sys.suspend(view.pid)

    try do
      payload = for number <- 1..100, do: %{identifier: to_string(number), title: String.duplicate("x", 128)}
      for _ <- 1..5_000, do: AgentPubSub.broadcast_running_change(payload)

      for _ <- 1..1_000 do
        Phoenix.PubSub.broadcast(Aiur.PubSub, "build_queue:changed", {:build_queue_changed, %{}})
        Phoenix.PubSub.broadcast(Aiur.PubSub, "build_progress", {:build_progress_changed, %{}})
      end

      Process.sleep(650)
      assert {:message_queue_len, length} = Process.info(view.pid, :message_queue_len)
      assert length <= 5
      assert {:message_queue_len, relay_length} = Process.info(relay, :message_queue_len)
      assert relay_length <= 1
      :erlang.garbage_collect(relay)
      assert {:memory, relay_bytes} = Process.info(relay, :memory)
      assert relay_bytes < 32_000_000
    after
      :sys.resume(view.pid)
    end

    :erlang.garbage_collect(view.pid)
    assert {:memory, bytes} = Process.info(view.pid, :memory)
    assert bytes < 32_000_000
    render_async(view)
    assert render(view) =~ "Flood root 100"
  end

  defp build_conn, do: Phoenix.ConnTest.build_conn() |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))

  defp restore(key, nil), do: Application.delete_env(:aiur, key)
  defp restore(key, value), do: Application.put_env(:aiur, key, value)
end
