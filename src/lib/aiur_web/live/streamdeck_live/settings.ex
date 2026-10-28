defmodule AiurWeb.StreamdeckLive.Settings do
  @moduledoc "LiveView adapter for shared deck settings navigation and persistence."

  alias AiurWeb.Streamdeck.Deck.{Nav, Settings, SettingsSnapshot}
  alias AiurWeb.Streamdeck.{FrameUpdates, SettingsUpdates}
  import Phoenix.Component, only: [assign: 2]

  @spec mount(Phoenix.LiveView.Socket.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def mount(socket, connected?) do
    path = Settings.path()
    snapshot = SettingsSnapshot.load(path)
    if connected?, do: SettingsSnapshot.subscribe(path)
    view = SettingsUpdates.default_view(snapshot.settings)
    socket |> assign(deck_settings_path: path, deck_nav: %{socket.assigns.deck_nav | view: view}) |> refresh()
  end

  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket), do: assign(socket, grid: SettingsSnapshot.attach(socket.assigns.grid, socket.assigns.deck_settings_path))

  @spec refresh_assigns(map()) :: map()
  def refresh_assigns(%{deck_settings_path: path} = assigns), do: Map.put(assigns, :grid, SettingsSnapshot.attach(assigns.grid, path))
  def refresh_assigns(assigns), do: assigns

  @spec open(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def open(socket) do
    nav = socket.assigns.deck_nav
    menu = %{section: nil, cursor: 0, return_surface: nav.surface, notice: nil}
    assign(socket, sd_mode: :settings, deck_nav: %{nav | surface: :settings, settings: menu})
  end

  @spec handles?(map(), Phoenix.LiveView.Socket.t()) :: boolean()
  def handles?(_raw, %{assigns: %{deck_nav: %Nav{surface: :settings}}}), do: true
  def handles?(%{"kind" => "dial", "index" => 3, "action" => "long_press"}, _socket), do: true
  def handles?(_raw, _socket), do: false

  @spec event(String.t(), map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def event(event, params, socket) do
    action = %{"dial-press" => "press", "dial-long-press" => "long_press", "dial-turn" => "turn"}[event]
    input(%{"kind" => "dial", "index" => integer(params["index"]), "action" => action, "delta" => integer(Map.get(params, "ticks", Map.get(params, "delta", 0)))}, socket)
  end

  @spec input(map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def input(raw, socket) do
    raw = raw |> Map.update("index", nil, &integer/1) |> Map.update("delta", 0, &integer/1)
    socket = refresh(socket)

    case FrameUpdates.transition(socket.assigns.deck_nav, raw, socket.assigns.grid) do
      {:ok, nav, effects} ->
        socket = assign(socket, deck_nav: nav, deck_effects: effects, sd_mode: nav.surface, deck_toast: nil)
        {:noreply, Enum.reduce(effects, socket, &apply_effect/2)}

      _invalid ->
        {:noreply, socket}
    end
  end

  defp apply_effect({:settings_set, patch}, socket) do
    applied = SettingsUpdates.apply_result(socket.assigns.deck_nav, patch, SettingsUpdates.save(patch, socket.assigns.deck_settings_path))
    socket |> assign(deck_nav: applied.nav, deck_toast: applied.toast) |> refresh()
  end

  defp apply_effect(_effect, socket), do: socket
  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _invalid -> nil
    end
  end

  defp integer(_value), do: nil
end
