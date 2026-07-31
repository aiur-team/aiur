defmodule Aiur.Cost.PricerTest do
  use ExUnit.Case, async: true

  alias Aiur.Cost.Pricer

  setup do
    {:ok, catalog} = Aiur.Usage.PriceTable.default()
    %{catalog: catalog}
  end

  defp claude_meta do
    %{
      provider: :claude,
      resolved_model: "claude-opus-4-8",
      relationship_revision: "claude-remote-control-2026-07",
      pricing_effective_date: ~D[2026-07-30],
      context_tier: nil
    }
  end

  defp codex_meta do
    %{
      provider: :codex,
      resolved_model: "gpt-5.6-luna",
      relationship_revision: "codex-app-server-2026-07",
      pricing_effective_date: ~D[2026-07-30],
      context_tier: :short_context
    }
  end

  test "prices claude input/cached/output at catalog rates", %{catalog: catalog} do
    tokens = %{input_tokens: 1_000_000, cached_input_tokens: 1_000_000, output_tokens: 1_000_000}
    {:ok, usd} = Pricer.usd(catalog, claude_meta(), tokens)
    # 5.00 + 0.50 + 25.00
    assert Decimal.equal?(usd, Decimal.new("30.50"))
  end

  test "zero-token dimensions need no price entry", %{catalog: catalog} do
    tokens = %{input_tokens: 2_000_000, cached_input_tokens: 0, output_tokens: 0}
    {:ok, usd} = Pricer.usd(catalog, claude_meta(), tokens)
    assert Decimal.equal?(usd, Decimal.new("10.00"))
  end

  test "prices codex by context tier", %{catalog: catalog} do
    tokens = %{input_tokens: 1_000_000, cached_input_tokens: 0, output_tokens: 1_000_000}
    {:ok, usd} = Pricer.usd(catalog, codex_meta(), tokens)
    # short_context luna: input 1.00 + output 6.00
    assert Decimal.equal?(usd, Decimal.new("7.00"))
  end

  test "unknown model yields an error", %{catalog: catalog} do
    meta = %{claude_meta() | resolved_model: "no-such-model"}
    assert {:error, _reason} = Pricer.usd(catalog, meta, %{input_tokens: 10, cached_input_tokens: 0, output_tokens: 0})
  end

  test "nil catalog is unavailable" do
    assert {:error, :price_table_unavailable} = Pricer.usd(nil, claude_meta(), %{input_tokens: 1, cached_input_tokens: 0, output_tokens: 0})
  end
end
