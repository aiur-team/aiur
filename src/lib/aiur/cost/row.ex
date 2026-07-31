defmodule Aiur.Cost.Row do
  @moduledoc """
  Renders a per-ticket cost snapshot into the operator-facing strings shown in
  the opencode agent pane.

  `compact/1` is the single line used above the chat scrollback (side-panel
  closed, the common state). `panel/1` is the two-line block for the open side
  panel. Both read the same snapshot, so the numbers are identical across
  surfaces.
  """

  @type snapshot :: %{
          optional(any()) => any(),
          context: %{tokens: non_neg_integer() | nil, limit: non_neg_integer() | nil, percent_used: non_neg_integer() | nil},
          cost: %{usd: Decimal.t() | number() | nil}
        }

  @doc "Compact single line, e.g. `Context 84,300 / 256K (33%) · $4.27 spent`."
  @spec compact(snapshot()) :: String.t()
  def compact(snapshot) when is_map(snapshot) do
    context = fetch(snapshot, :context, %{})
    tokens = fetch(context, :tokens, nil)
    limit = fetch(context, :limit, nil)
    percent = fetch(context, :percent_used, nil)

    context_part =
      case {tokens, limit} do
        {t, l} when is_integer(t) and is_integer(l) and l > 0 ->
          "Context #{commas(t)} / #{short(l)} (#{percent_text(percent)})"

        {t, _} when is_integer(t) ->
          "Context #{commas(t)} tokens"

        _ ->
          "Context —"
      end

    case usd(snapshot) do
      nil -> context_part
      usd -> context_part <> " · $#{usd} spent"
    end
  end

  @doc "Two-line side-panel block."
  @spec panel(snapshot()) :: String.t()
  def panel(snapshot) when is_map(snapshot) do
    context = fetch(snapshot, :context, %{})
    tokens = fetch(context, :tokens, nil)
    limit = fetch(context, :limit, nil)
    percent = fetch(context, :percent_used, nil)

    context_line =
      case {tokens, limit} do
        {t, l} when is_integer(t) and is_integer(l) and l > 0 ->
          "Context  #{commas(t)} / #{commas(l)} tokens  (#{percent_text(percent)})"

        {t, _} when is_integer(t) ->
          "Context  #{commas(t)} tokens"

        _ ->
          "Context  —"
      end

    cost_line =
      case usd(snapshot) do
        nil -> nil
        usd -> "Cost     $#{usd} spent"
      end

    [context_line, cost_line] |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  defp usd(snapshot) do
    case snapshot |> fetch(:cost, %{}) |> fetch(:usd, nil) do
      %Decimal{} = d -> d |> Decimal.round(2) |> Decimal.to_string(:normal)
      n when is_float(n) -> :erlang.float_to_binary(n, decimals: 2)
      n when is_integer(n) -> :erlang.float_to_binary(n * 1.0, decimals: 2)
      _ -> nil
    end
  end

  defp percent_text(p) when is_integer(p), do: "#{p}%"
  defp percent_text(_p), do: "—"

  # `256000` -> `256K`; small values stay literal.
  defp short(n) when is_integer(n) and n >= 1000, do: "#{round(n / 1000)}K"
  defp short(n) when is_integer(n), do: Integer.to_string(n)

  defp commas(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(",", &to_string/1)
  end

  defp fetch(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp fetch(_map, _key, default), do: default
end
