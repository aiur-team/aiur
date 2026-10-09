defmodule AiurWeb.BuildQueueLiveTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  alias AiurWeb.Endpoint
  @endpoint Endpoint

  defmodule QueueServer do
    use GenServer
    def start_link(model), do: GenServer.start_link(__MODULE__, model)
    @impl true
    def init(model), do: {:ok, model}
    @impl true
    def handle_call(:read_model, _from, model), do: {:reply, model, model}
    def handle_call({:put, model}, _from, _old), do: {:reply, :ok, model}
  end

  setup do
    server = start_supervised!({QueueServer, model(1)})
    parent = self()
    previous_reader = Application.get_env(:aiur, :build_queue_dashboard_reader)
    previous_endpoint = Application.get_env(:aiur, Endpoint)

    Application.put_env(:aiur, :build_queue_dashboard_reader, fn ->
      result = %{model: Aiur.BuildQueue.show(server), attentions: []}
      send(parent, :queue_read)
      result
    end)

    config = Application.get_env(:aiur, Endpoint, []) |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), dashboard_writable: false, dashboard_auth_required: false)
    Application.put_env(:aiur, Endpoint, config)
    Aiur.TestSupport.start_owned_endpoint!()

    on_exit(fn ->
      restore_application_env(:build_queue_dashboard_reader, previous_reader)
      restore_application_env(Endpoint, previous_endpoint)
    end)

    %{server: server}
  end

  test "panel is on the catalog, with no new route or mutation controls" do
    {:ok, view, _} = live(build_conn(), "/build-orders")
    assert_receive :queue_read, 2_000
    render_async(view)
    assert has_element?(view, "#build-queue-panel [data-queue-item='1']")
    refute has_element?(view, "#build-queue-panel button")
    {:ok, selected, _} = live(build_conn(), "/build-orders/42")
    refute has_element?(selected, "#build-queue-panel")
  end

  for {topic, event} <- [{"build_queue:changed", :build_queue_changed}, {"build_progress", :build_progress_changed}] do
    test "#{topic} subscription refreshes the panel and coalesces a burst", %{server: server} do
      {:ok, view, _} = live(build_conn(), "/build-orders")
      assert_receive :queue_read, 2_000
      render_async(view)
      assert has_element?(view, "[data-queue-item='1']")
      :ok = GenServer.call(server, {:put, model(2)})
      for _ <- 1..10, do: Phoenix.PubSub.broadcast(Aiur.PubSub, unquote(topic), {unquote(event), %{}})
      assert_receive :queue_read, 2_000
      render_async(view)
      assert has_element?(view, "[data-queue-item='2']")
      refute has_element?(view, "[data-queue-item='1']")
      refute_receive :queue_read, 600
    end
  end

  test "a timed-out read becomes unknown without dropping the page" do
    Application.put_env(:aiur, :build_queue_dashboard_reader, fn -> exit({:timeout, :read_model}) end)
    {:ok, view, _} = live(build_conn(), "/build-orders")
    render_async(view)
    assert has_element?(view, "#build-queue-panel[data-queue-state='unknown']")
    assert render(view) =~ "Queue readiness unknown."
    refute has_element?(view, "[data-queue-progress]")
    refute render(view) =~ "No open attentions"
  end

  defp model(number) do
    source = %{state: :ok, observed_at: DateTime.utc_now(), age_ms: 0, freshness: :current, reasons: []}
    item = %{number: number, position: 1, state: :waiting, reason: nil, rank: nil, downstream_open: nil, prerequisites: [], attention: nil}
    queue = %{queue_id: "q-abcd", name: "Next", held: false, items: [item], progress: %{completed: 0, total: 1, resolved: 1, percent: 0, resolution: :resolved}}
    %{status: :running, sources: %{"tracker_observation" => source}, queues: [queue]}
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)

  defp build_conn, do: Phoenix.ConnTest.build_conn() |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
end
