defmodule Aiur.ProviderMeters.Text do
  @moduledoc "Shared terminal formatting for provider allowances and credits."

  @spec bar(number()) :: String.t()
  def bar(percent) when is_number(percent) do
    filled = percent |> max(0) |> min(100) |> Kernel./(10) |> round()
    String.duplicate("█", filled) <> String.duplicate("░", 10 - filled)
  end

  @spec amount(number()) :: String.t()
  def amount(value), do: :erlang.float_to_binary(value / 1, decimals: 2)

  @spec freshness_suffix(map()) :: String.t()
  def freshness_suffix(%{freshness: :stale}), do: " [stale]"
  def freshness_suffix(_view), do: ""
end
