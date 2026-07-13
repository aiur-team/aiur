defmodule AiurWeb.ControlCenterCache do
  @moduledoc """
  Serializes and briefly caches the expensive Operator Control Center payload.

  Every connected dashboard receives the same PubSub notifications. Without a
  shared cache, one event fans out into one Orchestrator and provider read per
  browser. This cache makes the first caller refresh the payload while the
  remaining callers reuse that result for a short bounded interval.
  """

  use GenServer

  @type loader :: (-> map())

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, %{})
      name -> GenServer.start_link(__MODULE__, %{}, name: name)
    end
  end

  @spec fetch(GenServer.server(), term(), non_neg_integer(), loader()) :: map()
  def fetch(server, key, max_age_ms, loader)
      when is_integer(max_age_ms) and max_age_ms >= 0 and is_function(loader, 0) do
    GenServer.call(server, {:fetch, key, max_age_ms, loader}, :infinity)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:fetch, key, max_age_ms, loader}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)

    case Map.get(state, key) do
      %{loaded_at_ms: loaded_at_ms, payload: payload}
      when now_ms - loaded_at_ms < max_age_ms ->
        {:reply, payload, state}

      _other ->
        payload = loader.()
        entry = %{loaded_at_ms: System.monotonic_time(:millisecond), payload: payload}
        {:reply, payload, Map.put(state, key, entry)}
    end
  end
end
