defmodule AiurWeb.Streamdeck.SettingsUpdates do
  @moduledoc false
  alias AiurWeb.Streamdeck.Deck.{Nav, Settings, SettingsMenu}
  alias AiurWeb.Streamdeck.{FrameUpdates, Render}
  import Phoenix.Socket, only: [assign: 2]

  @spec initialize(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def initialize(socket) do
    {settings, error} =
      case Settings.read() do
        {:ok, settings} -> {settings, nil}
        {:error, _reason} -> {Settings.defaults(), "Settings unavailable"}
      end

    nav = socket.assigns.deck_nav
    view = Enum.find([:ticket, :feature, :epic, :fleet], &(Atom.to_string(&1) == settings["default_view"]))
    assign(socket, deck_settings: settings, deck_settings_path: Settings.path(), deck_devices: %{}, settings_menu: nil, settings_toast: error, deck_nav: %{nav | view: view})
  end

  @spec push(Phoenix.Socket.t()) :: :ok
  def push(socket), do: Phoenix.Channel.push(socket, "settings", socket.assigns.deck_settings)

  @spec devices(term(), Phoenix.Socket.t()) :: {:reply, tuple(), Phoenix.Socket.t()}
  def devices(payload, socket) do
    if valid_devices?(payload) do
      socket = assign(socket, deck_devices: Map.take(payload, ~w(mics speakers instances))) |> clamp_menu()
      socket = migrate(payload["legacy_mic_id"], socket)
      push(socket)
      {:reply, {:ok, %{}}, FrameUpdates.push(socket)}
    else
      {:reply, {:error, %{reason: "invalid_devices"}}, socket}
    end
  end

  @spec status(term(), Phoenix.Socket.t()) :: {:reply, tuple(), Phoenix.Socket.t()}
  def status(%{"text" => text}, socket) when is_binary(text) and byte_size(text) in 1..200 do
    socket = assign(socket, deck_toast: text, settings_toast: text)
    {:reply, {:ok, %{}}, FrameUpdates.push(socket)}
  end

  def status(_payload, socket), do: {:reply, {:error, %{reason: "invalid_status"}}, socket}

  @spec set(term(), Phoenix.Socket.t()) :: {:reply, tuple(), Phoenix.Socket.t()}
  def set(patch, socket) do
    case Settings.set(patch, socket.assigns.deck_settings_path) do
      {:ok, settings} ->
        nav = socket.assigns.deck_nav
        nav = if is_map(patch) and Map.has_key?(patch, "default_view"), do: %{nav | view: String.to_existing_atom(settings["default_view"]), stack: [], drill_pages: [], scroll: 0}, else: nav
        socket = assign(socket, deck_settings: settings, settings_toast: "Saved", deck_nav: nav)
        push(socket)
        {:reply, {:ok, settings}, FrameUpdates.push(socket)}

      {:error, _reason} ->
        socket = assign(socket, settings_toast: "Not saved", deck_toast: "Not saved")
        {:reply, {:error, %{reason: "not_saved"}}, FrameUpdates.push(socket)}
    end
  end

  @spec input(map(), Phoenix.Socket.t()) :: :pass | {:reply, tuple(), Phoenix.Socket.t()}
  def input(%{"kind" => "dial_long_press", "index" => 3}, %{assigns: %{settings_menu: nil, deck_nav: %Nav{stack: []}}} = socket), do: show(socket, %{section: nil, cursor: 0})
  def input(_input, %{assigns: %{settings_menu: nil}}), do: :pass

  def input(%{"kind" => "dial_long_press", "index" => 3}, socket) do
    menu = socket.assigns.settings_menu
    show(socket, if(is_nil(menu.section), do: nil, else: %{section: nil, cursor: 0}))
  end

  def input(%{"kind" => "dial_turn", "index" => 0, "ticks" => ticks}, socket) do
    menu = socket.assigns.settings_menu
    count = if is_nil(menu.section), do: 8, else: length(choices(socket))
    show(socket, %{menu | cursor: SettingsMenu.move(menu.cursor, ticks, count)})
  end

  def input(%{"kind" => "key_press", "index" => index}, socket) do
    menu = socket.assigns.settings_menu
    select(socket, if(is_nil(menu.section), do: index, else: div(menu.cursor, 8) * 8 + index))
  end

  def input(%{"kind" => "dial_press", "index" => 0}, socket), do: select(socket, socket.assigns.settings_menu.cursor)
  def input(_input, socket), do: {:reply, {:ok, %{}}, socket}

  @spec frame(Phoenix.Socket.t()) :: map()
  def frame(socket), do: Render.Settings.frame(socket.assigns.settings_menu, socket.assigns.deck_settings, socket.assigns.deck_devices, socket.assigns.settings_toast)

  @spec sort([map()], map()) :: [map()]
  def sort(agents, settings) do
    case settings["default_sort"] do
      "title" -> Enum.sort_by(agents, &String.downcase(to_string(&1[:title] || &1["title"] || "")))
      "priority" -> Enum.sort_by(agents, &{(&1[:priority] || &1["priority"]) != true, to_string(&1.identifier)})
      _state -> Enum.sort_by(agents, &{to_string(&1.bucket), to_string(&1.identifier)})
    end
  end

  defp show(socket, menu) do
    socket = assign(socket, settings_menu: menu, settings_toast: nil)
    {:reply, {:ok, %{}}, FrameUpdates.push(socket)}
  end

  defp select(%{assigns: %{settings_menu: %{section: nil}}} = socket, index) do
    {section, _label} = Enum.at(SettingsMenu.sections(), index)
    show(socket, %{section: section, cursor: 0})
  end

  defp select(socket, index) do
    case Enum.at(choices(socket), index) do
      nil -> {:reply, {:ok, %{}}, socket}
      choice -> set(%{socket.assigns.settings_menu.section => choice.value}, socket)
    end
  end

  defp clamp_menu(%{assigns: %{settings_menu: nil}} = socket), do: socket
  defp clamp_menu(%{assigns: %{settings_menu: %{section: nil}}} = socket), do: socket

  defp clamp_menu(socket) do
    menu = socket.assigns.settings_menu
    assign(socket, settings_menu: %{menu | cursor: SettingsMenu.move(menu.cursor, 0, length(choices(socket)))})
  end

  defp choices(socket), do: SettingsMenu.choices(socket.assigns.settings_menu.section, socket.assigns.deck_settings, socket.assigns.deck_devices)

  defp migrate(id, socket) when is_binary(id) and byte_size(id) in 1..256 do
    if File.exists?(socket.assigns.deck_settings_path) do
      socket
    else
      case Settings.set(%{"mic_id" => id}, socket.assigns.deck_settings_path) do
        {:ok, settings} -> assign(socket, deck_settings: settings)
        {:error, _reason} -> assign(socket, settings_toast: "Not saved")
      end
    end
  end

  defp migrate(_id, socket), do: socket

  defp valid_devices?(%{"mics" => mics, "speakers" => speakers} = payload) do
    valid_list?(mics) and valid_list?(speakers) and is_list(payload["instances"] || []) and length(payload["instances"] || []) <= 100 and
      Enum.all?(payload["instances"] || [], &(is_binary(&1) and byte_size(&1) in 1..256))
  end

  defp valid_devices?(_payload), do: false

  defp valid_list?(devices) when is_list(devices) and length(devices) <= 100 do
    Enum.all?(devices, fn
      %{"id" => id, "label" => label} -> is_binary(id) and byte_size(id) in 1..256 and is_binary(label) and byte_size(label) <= 256
      _invalid -> false
    end)
  end

  defp valid_list?(_devices), do: false
end
