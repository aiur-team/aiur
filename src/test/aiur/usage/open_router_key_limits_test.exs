defmodule Aiur.Usage.OpenRouterKeyLimitsTest do
  use ExUnit.Case, async: true

  alias Aiur.Usage.CLI
  alias Aiur.Usage.Provider.OpenRouter.KeyLimits

  @secret "sk-or-v1-secret-route-key"
  @observed_at ~U[2026-11-21 12:00:00Z]

  test "a key with a limit reports usage, the limit and the remaining amount" do
    payload = payload(fn _request -> ok(%{"usage" => 12.5, "limit" => 50, "limit_remaining" => 37.5, "is_free_tier" => false}) end)
    item = payload["provider"]

    assert item["observed_at"] == DateTime.to_iso8601(@observed_at)
    assert item["source"] == "openrouter_key_api"
    assert item["fields"]["state"] == "observed"

    assert item["fields"]["key"] == %{
             "state" => "reported",
             "observed_at" => DateTime.to_iso8601(@observed_at),
             "source" => "openrouter_key_api",
             "currency" => "USD",
             "usage" => 12.5,
             "limit" => 50,
             "limit_remaining" => 37.5,
             "is_free_tier" => false
           }

    assert item["fields"]["credits"] == %{"remaining" => 37.5, "limit" => 50, "used_percent" => 25.0, "basis" => "reported"}

    text = CLI.render(payload, "openrouter")
    assert text =~ "credits: $37.5 remaining of $50 limit (25.0% used)"
    assert text =~ "key: $12.5 used, $37.5 remaining of $50 limit (reported 2026-11-21T12:00:00Z)"
    refute text =~ @secret
    refute Jason.encode!(payload) =~ @secret
  end

  test "a key with no limit reports usage only" do
    payload = payload(fn _request -> ok(%{"usage" => 3, "limit" => nil, "limit_remaining" => nil, "is_free_tier" => true}) end)
    fields = payload["provider"]["fields"]

    assert fields["state"] == "observed"
    assert fields["credits"] == nil
    assert %{"state" => "reported", "usage" => 3, "limit" => nil, "is_free_tier" => true} = fields["key"]
    assert CLI.render(payload, "openrouter") =~ "key: $3 used, no limit, free tier"
  end

  test "an HTTP error degrades to no reading with a reason" do
    payload = payload(fn _request -> {:ok, %{status: 500, body: %{"error" => @secret}}} end)
    item = payload["provider"]

    assert item["observed_at"] == nil
    assert item["fields"]["state"] == "no_reading"
    assert item["fields"]["key"] == %{"state" => "no_reading", "reason" => "provider_error", "source" => "openrouter_key_api"}
    assert CLI.render(payload, "openrouter") =~ "key: no reading (provider_error)"
    refute Jason.encode!(payload) =~ @secret
  end

  test "the request carries the route key and reaches the key endpoint" do
    parent = self()

    KeyLimits.read(
      opts(fn request ->
        send(parent, {:request, request})
        ok(%{"usage" => 0})
      end)
    )

    assert_received {:request, %{url: "https://openrouter.ai/api/v1/key", headers: %{"authorization" => "Bearer " <> @secret}}}
  end

  test "readings, failures included, are cached for the poll interval" do
    counter = :counters.new(1, [])
    request = fn _request -> :counters.add(counter, 1, 1) && {:ok, %{status: 429, body: %{}}} end
    opts = opts(request) |> Keyword.merge(now_ms: 0, openrouter_key_poll_interval_ms: 1_000)

    assert %{state: :no_reading, reason: :rate_limited} = KeyLimits.read(opts)
    assert %{reason: :rate_limited} = KeyLimits.read(Keyword.put(opts, :now_ms, 999))
    assert :counters.get(counter, 1) == 1

    KeyLimits.read(Keyword.put(opts, :now_ms, 1_000))
    assert :counters.get(counter, 1) == 2
  end

  test "a missing key or backend config is no reading, without a request" do
    refute_request = fn _request -> flunk("no request expected") end

    assert %{state: :no_reading, reason: :missing_api_key} =
             KeyLimits.read(opts(refute_request) |> Keyword.put(:api_key_fetcher, fn _env -> nil end))

    assert %{state: :no_reading, reason: :not_configured} =
             KeyLimits.read(opts(refute_request) |> Keyword.put(:openrouter_backends, %{}))
  end

  defp payload(request_fun) do
    {:ok, payload} =
      CLI.payload("openrouter",
        meter_views: %{},
        openrouter_routes: [],
        openrouter_spend: %{api_equivalent: [], provider_reported: []},
        openrouter_key_limits: KeyLimits.read(opts(request_fun))
      )

    payload
  end

  defp opts(request_fun) do
    [
      openrouter_key_cache: make_ref(),
      observed_at: @observed_at,
      openrouter_backends: %{"openrouter" => %{openai_compat: %{base_url: "https://openrouter.ai/api/v1/", api_key_env: "OPENROUTER_API_KEY"}}},
      api_key_fetcher: fn "OPENROUTER_API_KEY" -> @secret end,
      openrouter_key_request_fun: request_fun
    ]
  end

  defp ok(data), do: {:ok, %{status: 200, body: %{"data" => data}}}
end
