defmodule Aiur.ElevenLabs.QuotaTest do
  # Every dependency is injected (credential fun, request fun, clock), so no
  # process-global state is touched and nothing here waits on a timer.
  use ExUnit.Case, async: true

  alias Aiur.ElevenLabs.Quota

  @now ~U[2026-08-15 12:00:00Z]
  @reset_unix 1_788_000_000

  test "projects usage and the next invoice amount due from the subscription response" do
    quota = start_quota()

    Quota.observe(
      quota,
      {:ok,
       response(%{
         "character_count" => 25_000,
         "character_limit" => 100_000,
         "tier" => "creator",
         "next_character_count_reset_unix" => @reset_unix,
         "currency" => "usd",
         "current_overage" => %{"amount" => "1.25", "currency" => "usd"},
         "next_invoice" => %{"amount_due_cents" => 500}
       })}
    )

    snapshot = Quota.snapshot(quota)

    assert snapshot.state == :observed
    assert snapshot.failure == nil
    assert snapshot.observed_at == @now

    assert snapshot.window == %{
             limit: 100_000,
             used: 25_000,
             remaining: 75_000,
             used_percent: 25.0,
             next_invoice: %{amount_due_cents: 500, currency: "USD"},
             tier: "creator",
             reset_at: DateTime.from_unix!(@reset_unix),
             observed_at: @now
           }
  end

  test "an unconfigured account is absent, never a failure" do
    quota = start_quota(api_key_fun: fn -> nil end)

    Quota.observe(quota, Quota.fetch(fn -> nil end, fn _key -> flunk("no request may be made without a key") end))

    snapshot = Quota.snapshot(quota)

    assert snapshot.state == :unconfigured
    assert snapshot.window == nil
    assert snapshot.failure == nil
  end

  test "an empty-string key is no key at all" do
    assert Quota.fetch(fn -> "" end, fn _key -> flunk("no request may be made without a key") end) == :unconfigured
  end

  # The distinction this module exists to keep: an unreadable configuration is
  # "no account", while a failed request against a configured key is a fault.
  test "a raising credential lookup reads as unconfigured rather than failed" do
    assert Quota.fetch(fn -> raise ArgumentError, "no config file" end, fn _key -> flunk("unreachable") end) == :unconfigured
  end

  test "a configured key whose request fails surfaces the failure" do
    for {status, reason} <- [{401, :authentication}, {403, :authentication}, {429, :rate_limited}, {500, :provider_error}] do
      quota = start_quota()
      Quota.observe(quota, {:ok, %{status: status, body: %{"detail" => "nope"}}})

      snapshot = Quota.snapshot(quota)

      assert snapshot.state == :failed, "status #{status} must surface as a failure"
      assert snapshot.failure == reason
      assert snapshot.window == nil
    end
  end

  test "a transport failure is named, and a raising request never escapes as a crash" do
    quota = start_quota()
    Quota.observe(quota, {:error, :transport})
    assert Quota.snapshot(quota).failure == :transport

    assert Quota.fetch(fn -> "xi-key" end, fn _key -> raise RuntimeError, "boom" end) == {:error, :probe_failed}
  end

  test "a configured key starts awaiting an answer rather than reporting one" do
    quota = start_quota()
    snapshot = Quota.snapshot(quota)

    assert snapshot.state == :unknown
    assert snapshot.window == nil
    assert snapshot.failure == nil
  end

  test "malformed and missing fields are a failure, not an invented quota" do
    for body <- [
          %{},
          %{"character_count" => 10},
          %{"character_limit" => 100},
          %{"character_count" => "10", "character_limit" => 100},
          %{"character_count" => 10, "character_limit" => nil},
          %{"character_count" => -1, "character_limit" => 100},
          "not a map"
        ] do
      quota = start_quota()
      Quota.observe(quota, {:ok, response(body)})

      snapshot = Quota.snapshot(quota)

      assert snapshot.state == :failed, "#{inspect(body)} must not produce a window"
      assert snapshot.failure == :malformed
      assert snapshot.window == nil
    end
  end

  # A zero limit is a real answer from a real account; it simply has no
  # percentage. The component renders that unknown percentage as an empty used
  # track, matching the neighboring meter idiom.
  test "a zero character limit reports no percentage instead of dividing by zero" do
    quota = start_quota()
    Quota.observe(quota, {:ok, response(%{"character_count" => 0, "character_limit" => 0})})

    snapshot = Quota.snapshot(quota)

    assert snapshot.state == :observed
    assert snapshot.window.limit == 0
    assert snapshot.window.remaining == 0
    assert snapshot.window.used_percent == nil
  end

  test "the used percentage clamps to its bounds without a Float.round/2 integer" do
    cases = [
      {0, 100_000, 0.0},
      {100_000, 100_000, 100.0},
      # An overage reports more consumed than the limit; used clamps at 100
      # rather than overflowing the meter track.
      {150_000, 100_000, 100.0},
      {33_333, 100_000, 33.3},
      {1, 3, 33.3}
    ]

    for {used, limit, expected} <- cases do
      quota = start_quota()
      Quota.observe(quota, {:ok, response(%{"character_count" => used, "character_limit" => limit})})

      window = Quota.snapshot(quota).window

      assert window.used_percent == expected
      assert is_float(window.used_percent)
      assert window.used_percent >= 0.0 and window.used_percent <= 100.0
    end
  end

  test "missing or malformed invoice data does not invalidate the credit quota" do
    for invoice <- [nil, %{}, %{"amount_due_cents" => -1}, %{"amount_due_cents" => "500"}] do
      quota = start_quota()

      Quota.observe(
        quota,
        {:ok,
         response(%{
           "character_count" => 25,
           "character_limit" => 100,
           "currency" => "usd",
           "next_invoice" => invoice
         })}
      )

      assert %{state: :observed, window: %{next_invoice: nil}} = Quota.snapshot(quota)
    end
  end

  test "the guaranteed invoice cents survive absent or malformed currency metadata" do
    for overage <- [nil, "invalid", [], %{}] do
      quota = start_quota()

      Quota.observe(
        quota,
        {:ok,
         response(%{
           "character_count" => 25,
           "character_limit" => 100,
           "current_overage" => overage,
           "next_invoice" => %{"amount_due_cents" => 500}
         })}
      )

      assert %{state: :observed, window: %{next_invoice: %{amount_due_cents: 500, currency: "USD"}}} = Quota.snapshot(quota)
      assert Process.alive?(quota)
    end
  end

  test "current overage currency is used when the top-level currency is absent" do
    quota = start_quota()

    Quota.observe(
      quota,
      {:ok,
       response(%{
         "character_count" => 25,
         "character_limit" => 100,
         "current_overage" => %{"currency" => "eur"},
         "next_invoice" => %{"amount_due_cents" => 500}
       })}
    )

    assert Quota.snapshot(quota).window.next_invoice == %{amount_due_cents: 500, currency: "EUR"}
  end

  test "an absent authority reports an absent account rather than a failure" do
    assert Quota.snapshot(:aiur_elevenlabs_quota_not_running) == %{state: :unconfigured, window: nil, failure: nil, observed_at: nil}
  end

  test "the credential never reaches the snapshot" do
    quota = start_quota()
    Quota.observe(quota, {:ok, response(%{"character_count" => 1, "character_limit" => 2})})

    refute inspect(Quota.snapshot(quota)) =~ "xi-secret"
    refute inspect(:sys.get_state(quota)) =~ "xi-secret"
  end

  test "fetch hands the resolved key to the request function and nothing else" do
    parent = self()

    result =
      Quota.fetch(fn -> "xi-secret" end, fn key ->
        send(parent, {:requested, key})
        {:ok, response(%{"character_count" => 0, "character_limit" => 10})}
      end)

    assert_received {:requested, "xi-secret"}
    assert {:ok, %{status: 200}} = result
  end

  defp start_quota(opts \\ []) do
    defaults = [
      name: nil,
      refresh?: false,
      clock: fn -> @now end,
      api_key_fun: fn -> "xi-secret" end,
      request_fun: fn _key -> {:error, :transport} end
    ]

    start_supervised!({Quota, Keyword.merge(defaults, opts)}, id: {Quota, System.unique_integer([:positive])})
  end

  defp response(body), do: %{status: 200, body: body}
end
