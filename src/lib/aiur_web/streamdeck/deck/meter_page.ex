defmodule AiurWeb.Streamdeck.Deck.MeterPage do
  @moduledoc "Attach provider keys and the selected account detail to a Fleet frame."
  alias AiurWeb.Streamdeck.Deck
  alias AiurWeb.Streamdeck.Deck.{Meters, Nav}
  alias AiurWeb.Streamdeck.Render
  alias AiurWeb.StreamdeckProjection
  alias Phoenix.{Channel, Socket}

  @spec prepare(map(), Nav.t()) :: map()
  def prepare(grid, %{view: view} = nav) when view in [:epic, :fleet] do
    usage = Meters.read()

    keys =
      usage
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {provider, meter} ->
        %{id: provider, kind: :meter_detail, title: "#{provider} usage", label: meter["summary_label"] || "Unknown", face: :idle, bucket: :paused}
      end)

    fleet =
      Map.update!(grid.fleet, :keys, fn categories ->
        categories = Enum.reject(categories, &match?(%{kind: :meter_detail}, &1))
        categories ++ List.duplicate(nil, max(8 - length(categories), 0)) ++ keys
      end)

    grid |> Map.merge(%{fleet: fleet, meter_usage: usage, meter_now_ms: System.system_time(:millisecond)}) |> focus(nav)
  end

  def prepare(grid, _nav), do: grid

  @spec focus(map(), Nav.t()) :: map()
  def focus(%{meter_detail: %{provider: provider}} = grid, %{stack: [{:meter_detail, provider} | _]}), do: grid

  def focus(grid, %{stack: [{:meter_detail, provider} | _]}) do
    now = DateTime.from_unix!(grid.meter_now_ms, :millisecond)
    Map.put(grid, :meter_detail, Meters.detail(provider, now: now))
  end

  def focus(grid, _nav), do: grid

  @spec sections(map()) :: map()
  def sections(%{meter_detail: %{provider: provider, accounts: accounts}} = grid), do: Map.put(Deck.navigation(grid), {:meter_detail, provider}, accounts)
  def sections(grid), do: Deck.navigation(grid)

  @spec refresh(Socket.t()) :: Socket.t()
  def refresh(%{assigns: %{deck_nav: %{view: :fleet} = nav}} = socket) do
    grid = StreamdeckProjection.grid() |> prepare(nav)
    Channel.push(socket, "frame", Render.frame(%{grid: grid, nav: nav}))
    Socket.assign(socket, :deck_frame_grid, grid)
  end

  def refresh(socket), do: socket
end
