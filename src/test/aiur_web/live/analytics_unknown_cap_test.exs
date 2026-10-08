defmodule AiurWeb.AnalyticsUnknownCapTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias AiurWeb.Endpoint
  alias AiurWeb.OperatorControlCenter.Analytics.Presenter

  @endpoint Endpoint
  @fixtures Path.expand("../../fixtures/run_telemetry", __DIR__)

  setup context do
    previous_telemetry = Application.get_env(:aiur, :analytics_telemetry_file)
    previous_endpoint = Application.get_env(:aiur, Endpoint)
    orchestrator = {:global, {__MODULE__, context.test}}

    endpoint_config =
      Keyword.merge(previous_endpoint || [],
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false,
        orchestrator: orchestrator
      )

    Application.put_env(:aiur, Endpoint, endpoint_config)
    Aiur.TestSupport.start_owned_endpoint!()

    on_exit(fn ->
      reset_env(:analytics_telemetry_file, previous_telemetry)
      reset_env(Endpoint, previous_endpoint)
    end)

    :ok
  end

  test "reports no wasted-capacity figure when no effective cap is known" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = live(build_conn(), "/analytics")

    # Idle slot-hours are a subtraction from the cap. With no cap reported the
    # page must not substitute the local config file and print a precise hour
    # count under a ceiling it just called unknown.
    assert html =~ ~r/\d+ at run end \/ unknown cap</

    assert {:ok, model} =
             Presenter.load(
               telemetry_file: @fixtures,
               orchestrator: Endpoint.config(:orchestrator)
             )

    assert model.cap == nil
    assert model.kpis.cap == nil
    refute html =~ ~r/>cap \d+<\/text>/
    refute html =~ ~s|fill="var(--blocking)" fill-opacity="0.07"|
    refute html =~ "unknown cap (configured"
    assert html =~ ~r/Wasted capacity<\/span>\s*<span class="an-kpi-val">—/
  end

  defp reset_env(key, nil), do: Application.delete_env(:aiur, key)
  defp reset_env(key, value), do: Application.put_env(:aiur, key, value)
end
