defmodule AiurWeb.Streamdeck.SettingsUpdates do
  @moduledoc false
  alias AiurWeb.Streamdeck.Deck.{Nav, Settings, SettingsSnapshot}
  alias AiurWeb.StreamdeckFleetUpdates
  import Phoenix.Socket, only: [assign: 2]

  @spec initialize(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def initialize(socket) do
    path = Settings.path()
    snapshot = SettingsSnapshot.load(path)
    :ok = SettingsSnapshot.subscribe(path)
    nav = socket.assigns.deck_nav
    view = default_view(snapshot.settings)
    assign(socket, deck_settings_path: path, deck_nav: %{nav | view: view})
  end

  @spec push(Phoenix.Socket.t()) :: :ok
  def push(socket) do
    snapshot = SettingsSnapshot.read(socket.assigns.deck_settings_path)
    payload = if snapshot.selection_id, do: Map.put(snapshot.settings, "instance_selection_id", snapshot.selection_id), else: snapshot.settings
    Phoenix.Channel.push(socket, "settings", payload)
  end

  @spec save(map(), Path.t()) :: {:ok, map()} | {:error, term()}
  def save(patch, path \\ Settings.path()), do: SettingsSnapshot.save(patch, path)

  @spec default_view(map()) :: :ticket | :feature | :epic | :fleet
  def default_view(settings), do: String.to_existing_atom(settings["default_view"])

  @doc "Apply a persisted settings result identically to channel and emulator navigation."
  @spec apply_result(Nav.t(), map(), {:ok, map()} | {:error, term()}) :: %{nav: Nav.t(), toast: String.t() | nil, result: :ok | {:error, String.t()}}
  def apply_result(nav, patch, {:ok, snapshot}) do
    nav = if Map.has_key?(patch, "default_view"), do: %{nav | view: default_view(snapshot.settings), stack: [], drill_pages: [], scroll: 0}, else: nav
    %{nav: %{nav | settings: %{nav.settings | notice: "Saved"}}, toast: nil, result: :ok}
  end

  def apply_result(nav, _patch, {:error, _reason}) do
    %{nav: %{nav | settings: %{nav.settings | notice: "Not saved"}}, toast: "Not saved", result: {:error, "not_saved"}}
  end

  @spec devices(term(), Phoenix.Socket.t()) :: {:reply, tuple(), Phoenix.Socket.t()}
  def devices(payload, socket) do
    if valid_devices?(payload) do
      SettingsSnapshot.devices(Map.take(payload, ~w(mics speakers instances availability)), socket.assigns.deck_settings_path)

      case migrate(payload["legacy_mic_id"], socket) do
        {:error, _reason} ->
          {:error, reason, socket} = not_saved(socket)
          reply(socket, {:error, %{reason: reason}})

        {:ok, snapshot} ->
          socket |> imported(snapshot) |> devices_reply()

        _result ->
          devices_reply(socket)
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
    applied = apply_result(socket.assigns.deck_nav, patch, save(patch, socket.assigns.deck_settings_path))
    socket = assign(socket, deck_nav: applied.nav, deck_toast: applied.toast)

    case applied.result do
      :ok ->
        push(socket)
        {:ok, socket}

      {:error, reason} ->
        {:error, reason, socket}
    end
  end

  defp not_saved(socket) do
    applied = apply_result(socket.assigns.deck_nav, %{}, {:error, :not_saved})
    {:error, "not_saved", assign(socket, deck_toast: applied.toast, deck_nav: applied.nav)}
  end

  defp imported(socket, snapshot) do
    applied = apply_result(socket.assigns.deck_nav, %{}, {:ok, snapshot})
    assign(socket, deck_toast: applied.toast, deck_nav: applied.nav)
  end

  defp devices_reply(socket) do
    push(socket)
    reply(socket, {:ok, %{}})
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
    valid_list?(mics) and valid_list?(speakers) and valid_availability?(payload["availability"]) and valid_instances?(payload["instances"])
  end

  defp valid_devices?(_payload), do: false

  defp valid_instances?(nil), do: true
  defp valid_instances?(instances) when is_list(instances) and length(instances) <= 100, do: Enum.all?(instances, &(is_binary(&1) and byte_size(&1) in 1..256))
  defp valid_instances?(_instances), do: false

  defp valid_availability?(nil), do: true
  defp valid_availability?(%{"mics" => mics, "speakers" => speakers} = flags), do: map_size(flags) == 2 and is_boolean(mics) and is_boolean(speakers)
  defp valid_availability?(_flags), do: false

  defp valid_list?(devices) when is_list(devices) and length(devices) <= 100 do
    Enum.all?(devices, fn
      %{"id" => id, "label" => label} -> is_binary(id) and byte_size(id) in 1..256 and is_binary(label) and byte_size(label) <= 256
      _invalid -> false
    end)
  end

  defp valid_list?(_devices), do: false
end
