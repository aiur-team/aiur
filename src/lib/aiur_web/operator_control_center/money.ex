defmodule AiurWeb.OperatorControlCenter.Money do
  @moduledoc """
  Render-time currency formatting for operator surfaces.

  Aggregation keeps exact decimals; this module rounds only at the point a
  value is shown so an operator reads `47.15 USD`, never the raw
  `47.145408500000006406` the arithmetic produced. A nonzero amount that
  rounds to zero is named `<0.01` so real spend is never rendered as nothing,
  and an unknown amount stays the word `unknown` rather than a guessed zero.
  """

  @scale 2

  @doc "Formats an exact amount to two decimals for display."
  @spec format_amount(Decimal.t() | String.t() | term()) :: String.t()
  def format_amount(%Decimal{} = amount) do
    rounded = Decimal.round(amount, @scale)

    if Decimal.eq?(rounded, 0) and not Decimal.eq?(amount, 0) do
      "<0.01"
    else
      Decimal.to_string(rounded, :normal)
    end
  end

  def format_amount(amount) when is_binary(amount) do
    case Decimal.parse(amount) do
      {decimal, ""} -> format_amount(decimal)
      _other -> amount
    end
  end

  def format_amount(_amount), do: "unknown"
end
