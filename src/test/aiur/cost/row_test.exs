defmodule Aiur.Cost.RowTest do
  use ExUnit.Case, async: true

  alias Aiur.Cost.Row

  defp snapshot do
    %{
      context: %{tokens: 84_300, limit: 256_000, percent_used: 33},
      cost: %{input_tokens: 412_300, output_tokens: 38_900, cached_input_tokens: 220_100, usd: Decimal.new("4.27")}
    }
  end

  test "compact line matches the issue format" do
    assert Row.compact(snapshot()) == "Context 84,300 / 256K (33%) · $4.27 spent"
  end

  test "omits cost when usd is unavailable" do
    snap = put_in(snapshot().cost.usd, nil)
    assert Row.compact(snap) == "Context 84,300 / 256K (33%)"
  end

  test "handles missing context limit" do
    snap = %{context: %{tokens: 500, limit: nil, percent_used: nil}, cost: %{usd: nil}}
    assert Row.compact(snap) == "Context 500 tokens"
  end

  test "tolerates string keys" do
    snap = %{"context" => %{"tokens" => 1_000, "limit" => 2_000, "percent_used" => 50}, "cost" => %{"usd" => 1.5}}
    assert Row.compact(snap) == "Context 1,000 / 2K (50%) · $1.50 spent"
  end
end
