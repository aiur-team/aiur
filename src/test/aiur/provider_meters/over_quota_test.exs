defmodule Aiur.ProviderMeters.OverQuotaTest do
  use ExUnit.Case, async: true

  alias Aiur.ProviderMeters.{Input, Reconciler}

  test "a provider's over-quota observation survives ingestion without becoming 100 percent" do
    now = ~U[2026-09-27 12:00:00Z]

    input = %{
      schema_version: 1,
      update_kind: :snapshot,
      provider: :codex,
      backend: :app_server,
      account_generation_binding: make_ref(),
      auth_mode: :unknown,
      observed_at: now,
      source: :synthetic,
      source_version: 1,
      windows: [%{limit_id: "weekly", kind: :rate_limit, name: :secondary, used_percent: 123.5, remaining_percent: 0, source: :synthetic, observed_at: now, coverage: :supported}]
    }

    assert {:ok, normalized} = Input.normalize(input)
    update = normalized |> Map.delete(:account_generation_binding) |> Map.put(:provider_account_generation, "test-generation")
    assert {:updated, snapshot} = Reconciler.apply(nil, update, now)
    assert snapshot.windows["weekly"].used_percent == 123.5
    assert snapshot.windows["weekly"].remaining_percent == 0
    # Existing safety constraints remain guards against future widening.
    for {key, value} <- [used_percent: -1, used_percent: 1_000_000_000_001, remaining_percent: 101] do
      invalid = put_in(input, [:windows], [Map.put(hd(input.windows), key, value)])
      assert {:error, :invalid_provider_meter_update} = Input.normalize(invalid)
    end
  end
end
