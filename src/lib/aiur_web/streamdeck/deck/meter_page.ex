defmodule AiurWeb.Streamdeck.Deck.MeterPage do
  @moduledoc "Attach cached provider keys and load selected account detail once per frame."
  alias AiurWeb.Streamdeck.Deck
  alias AiurWeb.Streamdeck.Deck.{Meters, Nav}

  @spec prepare(map(), Nav.t(), map()) :: {Nav.t(), map()}
  def prepare(grid, nav, usage) do
    grid = providers(grid, nav, usage)

    case {nav.surface, nav.stack} do
      {:grid, [{:meter_detail, provider} | _]} ->
        now = System.system_time(:millisecond)
        detail = Meters.detail(provider, now: DateTime.from_unix!(now, :millisecond))
        {%{nav | meter_count: length(detail.accounts)}, Map.merge(grid, %{meter_detail: detail, meter_now_ms: now})}

      _ ->
        {nav, grid}
    end
  end

  @spec sections(map(), Nav.t()) :: map()
  def sections(grid, nav), do: grid |> providers(nav, Map.get(grid, :meter_usage, %{})) |> Deck.navigation()

  defp providers(grid, %{view: view}, usage) when view in [:epic, :fleet] do
    keys =
      usage
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {provider, meter} ->
        %{id: provider, kind: :meter_detail, title: "#{provider} usage", label: meter["summary_label"] || "Unknown", face: :idle, bucket: :paused}
      end)

    fleet = Map.get(grid, :fleet, %{keys: []})
    categories = Enum.reject(Map.get(fleet, :keys, []), &match?(%{kind: :meter_detail}, &1))
    fleet = Map.put(fleet, :keys, categories ++ List.duplicate(nil, max(8 - length(categories), 0)) ++ keys)
    Map.merge(grid, %{fleet: fleet, meter_usage: usage})
  end

  defp providers(grid, _nav, _usage), do: grid
end
