defmodule Aiur.Usage.OpenRouterProviderTest do
  use ExUnit.Case, async: true

  alias Aiur.OpenAICompat.ProviderMeterProbe, as: OpenAICompatProbe
  alias Aiur.ProviderMeters.Events, as: MeterEvents
  alias Aiur.TestSupport.GroupedScopes, as: Cells
  alias Aiur.Usage.CLI
  alias Aiur.Usage.Provider.OpenRouter.Spend

  @route "openrouter:deepseek/deepseek-v4-flash"
  @model "deepseek/deepseek-v4-flash"

  test "a configured route with no reading reads as no reading, never an error" do
    assert {:ok, payload} =
             CLI.payload("openrouter",
               meter_views: %{},
               openrouter_routes: [@route],
               openrouter_spend: empty_spend()
             )

    item = payload["provider"]

    assert item["freshness"] == "unknown"
    assert item["observed_at"] == nil
    assert item["fields"]["state"] == "no_reading"
    assert item["fields"]["credits"] == nil
    assert [%{"route" => @route, "model" => @model, "state" => "no_reading", "readings" => []}] = item["fields"]["routes"]

    text = CLI.render(payload, "openrouter")
    assert text =~ "openrouter  unknown"
    assert text =~ "credits: no reading"
    assert text =~ "route: #{@route}  no reading"
  end

  test "a route with a reading reports its spend per model and the remaining credit against the limit" do
    spend = Spend.by_model(Cells.source([openrouter_record(upstream_provider: "DeepSeek")]))

    assert [%{upstream: "DeepSeek", model: @model, currency: "USD", amount: amount}] = spend.api_equivalent
    assert Decimal.compare(Decimal.new(amount), Decimal.new(0)) == :gt
    assert spend.provider_reported == []

    assert {:ok, payload} =
             CLI.payload("openrouter",
               meter_views: observed_view(),
               openrouter_routes: [@route],
               openrouter_spend: spend
             )

    item = payload["provider"]

    assert item["freshness"] == "fresh"
    assert item["observed_at"] == ~U[2026-11-05 12:00:00Z] |> DateTime.to_iso8601()
    assert item["fields"]["state"] == "observed"
    assert item["fields"]["credits"] == %{"remaining" => 77.5, "limit" => 100.0, "used_percent" => 22.5}

    assert [route] = item["fields"]["routes"]
    assert route["state"] == "observed"
    assert [%{"basis" => "api_equivalent", "upstream" => "DeepSeek", "amount" => ^amount}] = route["readings"]

    text = CLI.render(payload, "openrouter")
    assert text =~ "credits: $77.5 remaining of $100.0 limit (22.5% used)"
    assert text =~ "route: #{@route}  via DeepSeek $#{amount} USD (api_equivalent)"
  end

  test "the management key supplies the credit reading and the limit it is measured against" do
    :ok = MeterEvents.subscribe_observed()
    parent = self()

    assert %{observed?: true, reason: nil} =
             OpenAICompatProbe.probe(:openrouter, "openrouter",
               observed_at: ~U[2026-11-05 12:00:00Z],
               api_key_fetcher: fn env ->
                 send(parent, {:key_env, env})
                 "management-secret"
               end,
               openai_compat_request_fun: fn request ->
                 send(parent, {:request, request})
                 {:ok, %{status: 200, body: %{"data" => %{"total_credits" => 100, "total_usage" => 22.5}}}}
               end
             )

    assert_receive {:key_env, "OPENROUTER_MANAGEMENT_KEY"}, 1_000
    assert_receive {:provider_meter_changed, snapshot}, 1_000

    # The probe is the only observer of OpenRouter credit: the usage provider
    # reads what the probe published, so this asserts the two halves agree.
    view = %{state: :observed, observed_at: snapshot.observed_at, freshness: snapshot.freshness, windows: snapshot.windows}

    assert {:ok, payload} =
             CLI.payload("openrouter",
               meter_views: %{openrouter: view},
               openrouter_routes: [@route],
               openrouter_spend: empty_spend()
             )

    credits = payload["provider"]["fields"]["credits"]
    assert credits["remaining"] == 77.5
    assert credits["limit"] == 100
    assert credits["used_percent"] == 22.5
    assert CLI.render(payload, "openrouter") =~ "credits: $77.5 remaining of $100 limit (22.5% used)"
  end

  test "spend recorded for a route that is no longer configured is still reported" do
    spend = Spend.by_model(Cells.source([openrouter_record(upstream_provider: "DeepSeek")]))

    assert {:ok, payload} =
             CLI.payload("openrouter",
               meter_views: %{},
               openrouter_routes: ["openrouter:anthropic/claude-sonnet-5"],
               openrouter_spend: spend
             )

    assert [
             %{"route" => "openrouter:anthropic/claude-sonnet-5", "state" => "no_reading"},
             %{"route" => "openrouter:deepseek/deepseek-v4-flash", "state" => "observed"}
           ] = payload["provider"]["fields"]["routes"]

    assert payload["provider"]["fields"]["state"] == "observed"
    assert CLI.render(payload, "openrouter") =~ "route: openrouter:deepseek/deepseek-v4-flash  via DeepSeek"
  end

  test "an unreadable aggregate source reports absent spend, never zero" do
    assert Spend.by_model(nil) == empty_spend()
    assert Spend.by_model(%{cells: %{}}) == empty_spend()

    assert {:ok, payload} =
             CLI.payload("openrouter", meter_views: %{}, openrouter_routes: [@route], openrouter_spend: Spend.by_model(nil))

    assert payload["provider"]["fields"]["state"] == "no_reading"
  end

  defp observed_view do
    %{
      openrouter: %{
        state: :observed,
        observed_at: ~U[2026-11-05 12:00:00Z],
        freshness: :fresh,
        windows: %{"credits-remaining" => %{remaining: 77.5, limit: 100.0, used_percent: 22.5}}
      }
    }
  end

  defp openrouter_record(opts) do
    Cells.openrouter_record(1,
      upstream_provider: Keyword.get(opts, :upstream_provider),
      tokens: %{input: 1_000_000, output: 1_000_000}
    )
  end

  defp empty_spend, do: %{api_equivalent: [], provider_reported: []}
end
