defmodule AiurWeb.Streamdeck.SettingsUpdates do
  @moduledoc false
  alias AiurWeb.Streamdeck.Deck.{Settings, SettingsSnapshot}
  alias AiurWeb.StreamdeckFleetUpdates
  import Phoenix.Socket, only: [assign: 2]

  @spec initialize(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def initialize(socket) do
    path = Settings.path()
    snapshot = SettingsSnapshot.load(path)
    :ok = SettingsSnapshot.subscribe(path)
    nav = socket.assigns.deck_nav
    view = Enum.find([:ticket, :feature, :epic, :fleet], &(Atom.to_string(&1) == snapshot.settings["default_view"]))
    assign(socket, deck_settings_path: path, deck_nav: %{nav | view: view})
  end

  @spec push(Phoenix.Socket.t()) :: :ok
  def push(socket), do: Phoenix.Channel.push(socket, "settings", SettingsSnapshot.read(socket.assigns.deck_settings_path).settings)

  @spec save(map(), Path.t()) :: {:ok, map()} | {:error, term()}
  def save(patch, path \\ Settings.path()), do: SettingsSnapshot.save(patch, path)

  @spec devices(term(), Phoenix.Socket.t()) :: {:reply, tuple(), Phoenix.Socket.t()}
  def devices(payload, socket) do
    if valid_devices?(payload) do
      SettingsSnapshot.devices(Map.take(payload, ~w(mics speakers instances)), socket.assigns.deck_settings_path)

      case migrate(payload["legacy_mic_id"], socket) do
        {:error, _reason} ->
          {:error, reason, socket} = not_saved(socket)
          reply(socket, {:error, %{reason: reason}})

        _result ->
          push(socket)
          reply(socket, {:ok, %{}})
      end
    else
      {:reply, {:error, %{reason: "invalid_devices"}}, socket}
    end
  end

  @spec status(term(), Phoenix.Socket.t()) :: {:reply, tuple(), Phoenix.Socket.t()}
  def status(%{"text" => text}, socket) when is_binary(text) and byte_size(text) in 1..200 do
    nav = socket.assigns.deck_nav
    socket = assign(socket, deck_toast: text, deck_nav: %{nav | settings: %{nav.settings | notice: text}})
    reply(socket, {:ok, %{}})
  end

  def status(_payload, socket), do: {:reply, {:error, %{reason: "invalid_status"}}, socket}

  @spec set(term(), Phoenix.Socket.t()) :: {:reply, tuple(), Phoenix.Socket.t()}
  def set(patch, socket) do
    case apply_patch(socket, patch) do
      {:ok, socket} -> reply(socket, {:ok, SettingsSnapshot.read(socket.assigns.deck_settings_path).settings})
      {:error, reason, socket} -> reply(socket, {:error, %{reason: reason}})
    end
  end

  @spec effects(Phoenix.Socket.t(), [tuple()]) :: {:ok, Phoenix.Socket.t()} | {:error, String.t(), Phoenix.Socket.t()}
  def effects(socket, [{:settings_set, patch}]), do: apply_patch(socket, patch)
  def effects(socket, _effects), do: {:ok, socket}

  @spec changed(Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()}
  def changed(socket) do
    push(socket)
    StreamdeckFleetUpdates.schedule(socket)
  end

  @spec sort([map()], map()) :: [map()]
  def sort(agents, settings) do
    case settings["default_sort"] do
      "title" -> Enum.sort_by(agents, &String.downcase(to_string(&1[:title] || &1["title"] || "")))
      "priority" -> Enum.sort_by(agents, &((&1[:priority] || &1["priority"]) != true))
      _state -> agents
    end
  end

  defp apply_patch(socket, patch) do
    case save(patch, socket.assigns.deck_settings_path) do
      {:ok, snapshot} ->
        nav = socket.assigns.deck_nav
        nav = if Map.has_key?(patch, "default_view"), do: %{nav | view: String.to_existing_atom(snapshot.settings["default_view"]), stack: [], drill_pages: [], scroll: 0}, else: nav
        socket = assign(socket, deck_nav: %{nav | settings: %{nav.settings | notice: "Saved"}})
        push(socket)
        {:ok, socket}

      {:error, _reason} ->
        not_saved(socket)
    end
  end

  defp not_saved(socket) do
    nav = socket.assigns.deck_nav
    {:error, "not_saved", assign(socket, deck_toast: "Not saved", deck_nav: %{nav | settings: %{nav.settings | notice: "Not saved"}})}
  end

  defp reply(socket, result) do
    {:noreply, socket} = StreamdeckFleetUpdates.schedule(socket)
    {:reply, result, socket}
  end

  defp migrate(id, socket) when is_binary(id) and byte_size(id) in 1..256 do
    if not File.exists?(socket.assigns.deck_settings_path), do: save(%{"mic_id" => id}, socket.assigns.deck_settings_path)
  end

  defp migrate(_id, _socket), do: :ok

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
