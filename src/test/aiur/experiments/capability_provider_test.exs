defmodule Aiur.Experiments.CapabilityProviderTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.CapabilityProvider

  test "store availability preserves available, disabled and read-only causes" do
    for {status, expected} <- [
          {%{available?: true, store: :ok}, %{state: :available}},
          {%{available?: false, store: {:error, :disabled}}, %{state: :unavailable, reason: :disabled}},
          {%{available?: false, store: {:error, :store_read_only}}, %{state: :degraded, reason: :store_read_only}}
        ] do
      report = CapabilityProvider.capabilities(%{experiments_status: fn -> status end})
      assert report["experiments"] == expected
      assert report["experiments.metric_packs"] == %{state: :unavailable, reason: :not_installed}
    end
  end

  test "failed or unfamiliar status reads remain unknown" do
    for read <- [fn -> raise "unavailable" end, fn -> exit(:unavailable) end, fn -> :unexpected end] do
      assert CapabilityProvider.capabilities(%{experiments_status: read})["experiments"] == %{state: :unknown, reason: :unknown}
    end
  end

  test "default registry publishes both experiment ids" do
    providers = Application.fetch_env!(:aiur, :capability_providers)
    assert CapabilityProvider in providers
    assert CapabilityProvider.capability_ids() == ["experiments", "experiments.metric_packs"]
  end
end
