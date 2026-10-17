defmodule AiurWeb.AnalyticsLoadingTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias Aiur.RunTelemetry.Summaries
  alias Aiur.TestSupport.LiveViewAsync
  alias AiurWeb.Endpoint

  @endpoint Endpoint
  @summary Path.expand("../../fixtures/analytics/runs/boot-a/run-summary.json", __DIR__)

  defmodule SlowAnalyticsLive do
    use Phoenix.LiveView
    alias AiurWeb.OperatorControlCenter.Analytics.Runtime

    @impl true
    def mount(params, session, socket) do
      {:ok, socket} = AiurWeb.AnalyticsLive.mount(params, session, socket)
      parent = session["parent"]
      dataset = session["dataset"]

      loader = fn ->
        monitor = Process.monitor(parent)
        send(parent, {:scan_started, self()})

        receive do
          :release -> {[dataset], false}
          {:DOWN, ^monitor, :process, ^parent, _reason} -> exit(:test_requester_exited)
        end
      end

      {:ok, Runtime.load(socket, [cache_identity: session["identity"], prior_loader: loader], fn -> %{state: :absent, title: "Disabled", message: "Compression is disabled."} end)}
    end

    @impl true
    defdelegate handle_async(name, result, socket), to: AiurWeb.AnalyticsLive
    @impl true
    defdelegate handle_event(name, params, socket), to: AiurWeb.AnalyticsLive
    @impl true
    defdelegate handle_info(message, socket), to: AiurWeb.AnalyticsLive
    @impl true
    defdelegate render(assigns), to: AiurWeb.AnalyticsLive
  end

  setup context do
    root = Aiur.TestSupport.tmp_root!("analytics-loading")
    previous = for key <- [:repo_base_root, :analytics_repo, :analytics_telemetry_file, :analytics_rtk_opts, Endpoint], do: {key, Application.fetch_env(:aiur, key)}
    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :analytics_repo, "test/analytics")
    Application.put_env(:aiur, :analytics_telemetry_file, Path.join(root, "missing.ndjson"))
    Application.put_env(:aiur, :analytics_rtk_opts, enabled?: false)

    Application.put_env(
      :aiur,
      Endpoint,
      Keyword.merge(Application.get_env(:aiur, Endpoint, []),
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false,
        orchestrator: {:global, {__MODULE__, context.test}}
      )
    )

    Aiur.TestSupport.start_owned_endpoint!()

    on_exit(fn ->
      Aiur.TestSupport.restore_app_env(previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "first HTTP response stays under five seconds and skips analysis" do
    started = System.monotonic_time(:millisecond)
    conn = get(build_conn(), "/analytics")
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 5_000
    assert html_response(conn, 200) =~ "Loading run analytics"
    refute html_response(conn, 200) =~ "No run telemetry to analyze yet"
    IO.puts("cold /analytics HTTP response: #{elapsed} ms")
  end

  test "concurrent mounts stay responsive during one blocked retained scan and both receive charts" do
    {:ok, dataset} = @summary |> File.read!() |> Summaries.decode_summary()
    session = %{"parent" => self(), "identity" => make_ref(), "dataset" => dataset}
    {:ok, first, html} = live_isolated(build_conn(), SlowAnalyticsLive, session: session)
    assert html =~ "Loading run analytics"
    receive_barrier({:scan_started, worker})
    {:ok, second, html} = live_isolated(build_conn(), SlowAnalyticsLive, session: session)
    assert html =~ "Loading run analytics"
    assert render_click(first, "toggle-nav", %{}) =~ "Loading run analytics"
    send(worker, :release)

    for view <- [first, second] do
      rendered = LiveViewAsync.render_when_complete(view)
      assert rendered =~ "Peak concurrency"
      assert rendered =~ ~s(data-source-kind="retained")
      refute rendered =~ "Loading run analytics"
    end

    refute_received {:scan_started, _worker}
  end

  test "blocked analytics scan shows elapsed loading time then a named timeout" do
    previous = Application.fetch_env(:aiur, :analytics_load_timeout_ms)
    Application.put_env(:aiur, :analytics_load_timeout_ms, 1_500)
    on_exit(fn -> Aiur.TestSupport.restore_app_env(analytics_load_timeout_ms: previous) end)

    {:ok, dataset} = @summary |> File.read!() |> Summaries.decode_summary()
    session = %{"parent" => self(), "identity" => make_ref(), "dataset" => dataset}
    {:ok, view, html} = live_isolated(build_conn(), SlowAnalyticsLive, session: session)
    assert html =~ "Loading run analytics"
    receive_barrier({:scan_started, _worker})

    assert eventually(fn -> render(view) =~ "waited 1s" end, 500)
    assert eventually(fn -> render(view) =~ "Run analytics timed out." end, 500)
    rendered = render(view)
    assert rendered =~ "within 1.5 seconds"
    refute rendered =~ "Loading run analytics"
    assert length(:binary.matches(rendered, ~s(data-empty-reason="timeout"))) == 1
  end

  test "async worker exits become an unavailable state" do
    {:ok, view, _html} = live(build_conn(), "/analytics")
    LiveViewAsync.render_when_complete(view)
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, range: :run, unavailable: :loading}}

    assert capture_log(fn ->
             {:noreply, failed} = AiurWeb.AnalyticsLive.handle_async(:analytics_model, {:exit, :killed}, socket)
             assert failed.assigns.unavailable == :error
             assert failed.assigns.model == nil
           end) =~ "Analytics loading failed: :killed"
  end

  defp build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
  end

  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
