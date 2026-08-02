defmodule Aiur.OpenAICompat.MeterAdapterTest do
  use ExUnit.Case, async: true

  alias Aiur.OpenAICompat.MeterAdapter
  alias Aiur.ProviderMeters.Input

  @observed_at ~U[2026-08-01 12:00:00Z]

  test "Kimi converts throughput headers into an honest used and remaining window" do
    parent = self()

    completion = %{
      headers: %{
        "x-ratelimit-limit" => "1000",
        "x-ratelimit-remaining" => "750",
        "x-ratelimit-reset" => "60"
      }
    }

    assert :ok =
             MeterAdapter.observe(completion, state(:kimi),
               meter_observed_at: @observed_at,
               meter_ingester: fn update -> send(parent, {:meter, update}) end
             )

    assert_receive {:meter, update}
    assert update.provider == :kimi
    assert update.backend == :openai_compat
    assert update.update_kind == :patch
    assert update.source == :kimi_api

    assert [window] = update.windows
    assert window.used_percent == 25.0
    assert window.limit == 1000.0
    assert window.remaining == 750.0
    assert window.resets_at == ~U[2026-08-01 12:01:00Z]
  end

  test "Kimi emits no meter when required headers are absent" do
    parent = self()

    assert :ok =
             MeterAdapter.observe(%{headers: %{}}, state(:kimi), meter_ingester: fn update -> send(parent, {:meter, update}) end)

    refute_receive {:meter, _update}
  end

  test "DeepSeek reports local concurrency headroom without claiming a provider percentage" do
    parent = self()

    assert :ok =
             MeterAdapter.observe(%{local_in_flight: 25}, state(:deepseek),
               meter_observed_at: @observed_at,
               meter_ingester: fn update -> send(parent, {:meter, update}) end
             )

    assert_receive {:meter, %{windows: [window]}}
    assert window.name == :concurrency
    assert window.used == 25
    assert window.limit == 2_500
    assert window.remaining == 2_475
    assert window.used_percent == 1.0
    assert window.expires_at == ~U[2026-08-01 12:01:00Z]
  end

  # The adapter emits through a caller-supplied ingester in the tests above, so
  # on its own it never proves the store would accept what it emits. Run the
  # real updates through the store's own normalizer: a backend, source, or
  # window name the registry-derived allowlists reject would otherwise only show
  # up as a silently dropped meter at runtime.
  test "the updates both providers emit are accepted by the store's normalizer" do
    parent = self()

    completion = %{headers: %{"x-ratelimit-limit" => "1000", "x-ratelimit-remaining" => "750"}}

    for {provider, payload} <- [{:kimi, completion}, {:deepseek, %{local_in_flight: 25}}] do
      assert :ok =
               MeterAdapter.observe(payload, state(provider),
                 meter_observed_at: @observed_at,
                 meter_ingester: fn update -> send(parent, {:meter, update}) end
               )

      assert_receive {:meter, update}
      assert {:ok, normalized} = Input.normalize(update)
      assert normalized.provider == provider
      assert normalized.backend == :openai_compat
    end
  end

  defp state(provider) do
    %{
      account_generation: %{
        account_generation_binding: make_ref(),
        account_generation_provider: provider
      }
    }
  end
end
