defmodule Aiur.AgentContextPresentation do
  @moduledoc "Formats an agent's observed context occupancy for compact and detailed views."

  @spec label(map() | nil) :: String.t()
  def label(%{used_tokens: used, window_tokens: capacity} = context)
      when is_integer(used) and used >= 0 and is_integer(capacity) and capacity > 0 do
    "#{used} / #{capacity} tokens (#{round(used * 100 / capacity)}%)" <> pressure_suffix(context)
  end

  def label(%{used_tokens: used} = context) when is_integer(used) and used >= 0,
    do: "#{used} tokens / unknown capacity" <> pressure_suffix(context)

  def label(_), do: "—"

  @spec compact(map() | nil) :: String.t()
  def compact(%{used_tokens: used, window_tokens: capacity})
      when is_integer(used) and used >= 0 and is_integer(capacity) and capacity > 0 do
    percent = round(used * 100 / capacity)
    detail = "#{percent}% #{short(used)}/#{short(capacity)}"
    if String.length(detail) <= 12, do: detail, else: "#{percent}% ctx"
  end

  def compact(%{used_tokens: used}) when is_integer(used) and used >= 0,
    do: "#{short(used)}/? ctx"

  def compact(_), do: "—"

  defp pressure_suffix(%{pressure: :warning}), do: " · warning"
  defp pressure_suffix(%{pressure: :blocked}), do: " · blocked"
  defp pressure_suffix(_), do: ""

  defp short(n) when n < 1_000, do: Integer.to_string(n)
  defp short(n) when n < 10_000, do: :erlang.float_to_binary(n / 1_000, decimals: 1) <> "k"
  defp short(n) when n < 1_000_000, do: Integer.to_string(div(n, 1_000)) <> "k"
  defp short(n) when n < 10_000_000, do: :erlang.float_to_binary(n / 1_000_000, decimals: 1) <> "m"
  defp short(n), do: Integer.to_string(div(n, 1_000_000)) <> "m"
end
