defmodule AiurWeb.ExperimentsChartsLiveTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  alias AiurWeb.Endpoint
  @endpoint Endpoint

  defmodule Facade do
    alias Aiur.Experiments.ChartData
    def status, do: %{available?: true, store: :ok, capture: :on}
    def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, "chart-live-test")
    def metric_catalog, do: %{metrics: %{}}
    def list, do: {:ok, [%{id: "chart-example", title: "Example", status: "active", created_at: nil}]}
    def fetch("chart-example"), do: {:ok, Application.fetch_env!(:aiur, :chart_live_fixture)}
    def chart_detail(id, opts), do: ChartData.attach(fetch(id), opts)
  end

  defp build_conn, do: Phoenix.ConnTest.build_conn() |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))

  setup do
    previous = Map.new([:experiments_facade, :chart_live_fixture, Endpoint], &{&1, Application.get_env(:aiur, &1)})
    raw = File.read!(Path.expand("../../aiur/experiments/fixtures/chart_detail.json", __DIR__)) |> Jason.decode!()
    detail = %{spec: raw["spec"], analysis: raw["analysis"], snapshots: raw["snapshots"], annotations: raw["annotations"], phase: :collecting}
    Application.put_env(:aiur, :experiments_facade, Facade)
    Application.put_env(:aiur, :chart_live_fixture, detail)
    Application.put_env(:aiur, Endpoint, Keyword.merge(previous[Endpoint] || [], server: false, dashboard_auth_required: false, secret_key_base: String.duplicate("s", 64)))
    Aiur.TestSupport.start_owned_endpoint!()
    on_exit(fn -> for {key, value} <- previous, do: if(is_nil(value), do: Application.delete_env(:aiur, key), else: Application.put_env(:aiur, key, value)) end)
    :ok
  end

  test "metric links patch URL and update selected charts; unknown metric falls back" do
    {:ok, view, _} = live(build_conn(), "/experiments/chart-example?metric=missing")
    assert has_element?(view, ".exp-metric-links a[aria-current=true]", "delivery-speed/start_to_merge")
    view |> element(".exp-metric-links a", "delivery-speed/pr_open_to_merge") |> render_click()
    assert_patch(view, "/experiments/chart-example?metric=delivery-speed%2Fpr_open_to_merge")
    assert has_element?(view, "h3", "Distribution: delivery-speed/pr_open_to_merge")
    assert has_element?(view, "h3", "Time series: delivery-speed/pr_open_to_merge")
    view |> form(".exp-metric-select", metric: "delivery-speed/start_to_merge") |> render_change()
    assert_patch(view, "/experiments/chart-example?metric=delivery-speed%2Fstart_to_merge")
  end

  test "stratum chips drive facade selection and point tables match the SVG population" do
    {:ok, view, _} = live(build_conn(), "/experiments/chart-example")
    view |> element(".exp-strata a", "2") |> render_click()
    assert_patch(view, "/experiments/chart-example?metric=delivery-speed%2Fstart_to_merge&stratum=complexity%3A2")
    assert has_element?(view, ".exp-strata a[aria-current=true]", "2")
    html = render(view) |> Floki.parse_document!()
    assert length(Floki.find(html, "#exp-charts svg .exp-point")) == 16
    samples = Enum.filter(Floki.find(html, "#exp-charts table"), fn table -> Floki.text(Floki.find(table, "caption")) in ["Distribution samples", "Time series samples"] end)
    assert length(samples) == 2
    for table <- samples, do: assert(length(Floki.find(table, "tbody tr")) == 8)
    assert render(view) =~ "needs 8 more after the line"
  end
end
