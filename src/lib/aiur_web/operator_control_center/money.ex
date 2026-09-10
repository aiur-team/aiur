defmodule AiurWeb.OperatorControlCenter.Money do
  @moduledoc """
  Render-time currency formatting for operator surfaces.

  Aggregation keeps exact decimals; this module rounds only at the point a
  value is shown so an operator reads `47.15 USD`, never the raw
  `47.145408500000006406` the arithmetic produced. A nonzero amount that
  rounds to zero is named `<0.01` (`-<0.01` when negative) so real spend is
  never rendered as nothing, and an unknown amount stays the word `unknown`
  rather than a guessed zero.

  `exact_string/1` is the companion for anything that must keep arithmetic
  precision (sorting, summing): the formatted string is for eyes only.
  """

  @scale 2

  @doc "Formats an exact amount to two decimals for display."
  @spec format_amount(Decimal.t() | String.t() | term()) :: String.t()
  def format_amount(%Decimal{} = amount) do
    rounded = Decimal.round(amount, @scale)

    cond do
      not Decimal.eq?(rounded, 0) or Decimal.eq?(amount, 0) -> Decimal.to_string(rounded, :normal)
      Decimal.negative?(amount) -> "-<0.01"
      true -> "<0.01"
    end
  end

  def format_amount(amount) when is_binary(amount) do
    case Decimal.parse(amount) do
      {decimal, ""} -> format_amount(decimal)
      _other -> amount
    end
  end

  def format_amount(_amount), do: "unknown"

  @doc "The exact decimal as a string, for values that are summed or sorted rather than read."
  @spec exact_string(Decimal.t() | String.t() | term()) :: String.t() | nil
  def exact_string(%Decimal{} = amount), do: Decimal.to_string(amount, :normal)

  def exact_string(amount) when is_binary(amount) do
    case Decimal.parse(amount) do
      {decimal, ""} -> Decimal.to_string(decimal, :normal)
      _other -> nil
    end
  end

  def exact_string(_amount), do: nil
end
