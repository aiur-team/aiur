defmodule AiurWeb.Streamdeck.Deck.SettingsSnapshot do
  @moduledoc "Bounded shared settings and PC inventory; frame composition only reads retained values."
  use GenServer
  alias AiurWeb.Streamdeck.Deck.Settings
  @limit 32

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))

  @spec read(Path.t()) :: map()
  def read(path \\ Settings.path()), do: GenServer.call(__MODULE__, {:read, path})

  @spec load(Path.t()) :: map()
  def load(path \\ Settings.path()), do: GenServer.call(__MODULE__, {:load, path})

  @spec attach(map(), Path.t()) :: map()
  def attach(grid, path \\ Settings.path()), do: Map.put(grid, :settings_snapshot, read(path))

  @spec save(map(), Path.t()) :: {:ok, map()} | {:error, term()}
  def save(patch, path \\ Settings.path()), do: GenServer.call(__MODULE__, {:save, path, patch})

  @spec devices(map(), Path.t()) :: map()
  def devices(inventory, path \\ Settings.path()), do: GenServer.call(__MODULE__, {:devices, path, inventory})

  @spec subscribe(Path.t()) :: :ok | {:error, term()}
  def subscribe(path \\ Settings.path()), do: Phoenix.PubSub.subscribe(Aiur.PubSub, topic(path))

  @spec unavailable() :: map()
  def unavailable, do: %{settings: Settings.defaults(), devices: nil, status: :unavailable}

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:read, path}, _from, state), do: {:reply, payload(state, path), state}

  def handle_call({:load, path}, _from, state) do
    state = ensure_loaded(state, path)
    {:reply, payload(state, path), state}
  end

  def handle_call({:save, path, patch}, _from, state) do
    case Settings.set(patch, path) do
      {:ok, settings} ->
        entry = Map.get(state, path, entry(unavailable()))
        state = put_entry(state, path, %{entry | payload: %{entry.payload | settings: settings, status: :ok}})
        notify(path)
        {:reply, {:ok, payload(state, path)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:devices, path, devices}, {owner, _tag}, state) do
    state = ensure_loaded(state, path)
    entry = Map.fetch!(state, path)
    if entry.monitor, do: Process.demonitor(entry.monitor, [:flush])
    entry = %{entry | payload: %{entry.payload | devices: devices}, monitor: Process.monitor(owner)}
    state = put_entry(state, path, entry)
    notify(path)
    {:reply, payload(state, path), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _owner, _reason}, state) do
    state =
      Map.new(state, fn {path, entry} ->
        if entry.monitor == ref do
          notify(path)
          {path, %{entry | monitor: nil, payload: %{entry.payload | devices: nil}}}
        else
          {path, entry}
        end
      end)

    {:noreply, state}
  end

  defp ensure_loaded(state, path) do
    if Map.has_key?(state, path) do
      state
    else
      snapshot =
        case Settings.read(path) do
          {:ok, settings} -> %{settings: settings, devices: nil, status: :ok}
          {:error, _reason} -> unavailable()
        end

      put_entry(state, path, entry(snapshot))
    end
  end

  defp entry(snapshot), do: %{payload: snapshot, monitor: nil, order: System.unique_integer([:monotonic, :positive])}

  defp payload(state, path) do
    case Map.get(state, path) do
      nil -> unavailable()
      entry -> entry.payload
    end
  end

  defp put_entry(state, path, entry) do
    state = Map.put(state, path, entry)

    if map_size(state) > @limit do
      {old_path, old_entry} = Enum.min_by(state, fn {_path, entry} -> entry.order end)
      if old_entry.monitor, do: Process.demonitor(old_entry.monitor, [:flush])
      Map.delete(state, old_path)
    else
      state
    end
  end

  defp topic(path), do: "streamdeck:settings:" <> Base.url_encode64(:crypto.hash(:sha256, path), padding: false)
  defp notify(path), do: Phoenix.PubSub.broadcast(Aiur.PubSub, topic(path), {:streamdeck_settings_changed, path})
end
