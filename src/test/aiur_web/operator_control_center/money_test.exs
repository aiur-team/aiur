defmodule AiurWeb.OperatorControlCenter.MoneyTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.Money

  test "renders a float-scaled exact decimal as two-decimal currency" do
    assert Money.format_amount(Decimal.new("47.145408500000006406")) == "47.15"
    assert Money.format_amount("47.145408500000006406") == "47.15"
  end

  test "keeps whole and short amounts at two decimals" do
    assert Money.format_amount(Decimal.new("3")) == "3.00"
    assert Money.format_amount(Decimal.new("2.5")) == "2.50"
  end

  test "names sub-cent spend instead of rounding it to nothing" do
    assert Money.format_amount(Decimal.new("0.004")) == "<0.01"
    assert Money.format_amount(Decimal.new("0")) == "0.00"
  end

  test "leaves an unparseable or unknown amount unguessed" do
    assert Money.format_amount("unknown") == "unknown"
    assert Money.format_amount(nil) == "unknown"
  end
end
