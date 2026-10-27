defmodule Aiur.BuildOrder.Estimates do
  @moduledoc "Durable per-ticket estimate overrides; unavailable stores never imply default estimates."
  use GenServer

  alias Aiur.BuildOrder.Estimates.Store
  alias Aiur.BuildOrder.ProviderHealth
  @default_hours %{1 => 1, 2 => 2, 3 => 4, 4 => 7, 5 => 11}
  @topic "build-estimates:changed"

  @type record :: %{hours: number(), reason: String.t(), by: String.t(), at: DateTime.t()}

  @spec default_hours(term()) :: pos_integer() | nil
  def default_hours(cx), do: Map.get(@default_hours, cx)

  @spec resolve(map(), map() | :unavailable) :: map()
  def resolve(_row, :unavailable), do: %{est: nil, override: nil}

  def resolve(%{num: n, cx: cx}, overrides),
    do: %{est: default_hours(cx), override: if(is_integer(n) and n > 0, do: json_override(Map.get(overrides, n)))}

  defp json_override(nil), do: nil
  defp json_override(record), do: Map.update!(record, :at, &DateTime.to_unix(&1, :millisecond))

  @spec validate(term(), term(), term(), term()) :: {:ok, String.t()} | {:error, atom()}
  def validate(id, hours, reason, by) do
    cond do
      not (is_integer(id) and id > 0) -> {:error, :invalid_id}
      hours != :clear and not valid_hours?(hours) -> {:error, :invalid_hours}
      not valid_reason?(reason) -> {:error, :invalid_reason}
      not valid_by?(by) -> {:error, :invalid_by}
      true -> {:ok, String.trim(reason)}
    end
  end

  @doc false
  @spec valid_hours?(term()) :: boolean()
  def valid_hours?(n), do: is_number(n) and n >= 0.25 and n <= 999 and trunc(n * 4) == n * 4
  @doc false
  @spec valid_reason?(term()) :: boolean()
  def valid_reason?(s), do: is_binary(s) and String.valid?(s) and String.length(String.trim(s)) in 1..500 and not Regex.match?(~r/[\p{Cc}\p{Cf}]/u, s)
  @doc false
  @spec valid_by?(term()) :: boolean()
  def valid_by?(s), do: is_binary(s) and Regex.match?(~r/\A[A-Za-z0-9._:@-]{1,64}\z/, s)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  @spec put(pos_integer(), number(), String.t(), String.t(), keyword()) :: {:ok, record()} | {:error, term()}
  def put(id, hours, reason, by, opts \\ [])
  def put(id, hours, reason, by, opts) when is_number(hours), do: call({:write, id, hours, reason, by, opts}, opts)
  def put(_id, _hours, _reason, _by, _opts), do: {:error, :invalid_hours}
  @spec clear(pos_integer(), String.t(), String.t(), keyword()) :: {:ok, :cleared | :absent} | {:error, term()}
  def clear(id, reason, by, opts \\ []), do: call({:write, id, :clear, reason, by, opts}, opts)
  @spec get(pos_integer(), keyword()) :: {:ok, map()} | {:error, ProviderHealth.t()}
  def get(id, opts \\ []), do: call({:get, id}, opts)
  @spec snapshot(keyword()) :: {:ok, map()} | {:error, ProviderHealth.t()}
  def snapshot(opts \\ []), do: call(:snapshot, opts)
  @spec overrides(keyword()) :: {:ok, map()} | {:error, ProviderHealth.t()}
  def overrides(opts \\ []) do
    with {:ok, snapshot} <- snapshot(opts), do: {:ok, snapshot.overrides}
  end

  @spec health(keyword()) :: ProviderHealth.t()
  def health(opts \\ []), do: call(:health, opts)
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)

  defp call(message, opts) do
    timeout = if match?({:write, _, _, _, _, _}, message), do: :infinity, else: 5_000
    GenServer.call(Keyword.get(opts, :server, __MODULE__), message, timeout)
  catch
    :exit, _ ->
      health = %ProviderHealth{failure: :estimates_unavailable}
      if message == :health, do: health, else: {:error, health}
  end

  @impl true
  def init(opts), do: {:ok, Store.load(opts), {:continue, :loaded}}

  @impl true
  def handle_continue(:loaded, state) do
    broadcast(state, [])
    {:noreply, state}
  end

  @impl true
  def handle_call(:health, _from, state), do: {:reply, state.health, state}
  def handle_call({:write, _, _, _, _, _}, _from, %{health: %{state: :unavailable}} = state), do: {:reply, {:error, :estimates_unavailable}, state}
  def handle_call(_message, _from, %{health: %{state: :unavailable}} = state), do: {:reply, {:error, state.health}, state}
  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, %{overrides: all_overrides(state), health: state.health}}, state}
  def handle_call({:get, id}, _from, state), do: {:reply, {:ok, Map.get(state.tickets, id, %{override: nil, journal: []})}, state}

  def handle_call({:write, id, hours, reason, by, opts}, _from, state) do
    with {:ok, reason} <- validate(id, hours, reason, by),
         {:ok, at} <- now(opts) do
      entry = %{hours: if(hours == :clear, do: nil, else: hours), reason: reason, by: by, at: at}
      old = Map.get(state.tickets, id, %{override: nil, journal: []})
      override = if hours == :clear, do: nil, else: entry
      changed? = effective(old.override) != effective(override)
      ticket = %{override: override, journal: Enum.take([Map.put(entry, :op, if(hours == :clear, do: :clear, else: :set)) | old.journal], 20)}
      next = %{state | tickets: Map.put(state.tickets, id, ticket), generation: state.generation + if(changed?, do: 1, else: 0)}
      persist(state, next, id, changed?, result(hours, old, override))
    else
      error -> {:reply, error, state}
    end
  end

  defp now(opts) do
    value = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case value do
      %DateTime{utc_offset: 0, std_offset: 0} -> {:ok, value}
      _ -> {:error, :invalid_time}
    end
  end

  defp effective(nil), do: nil
  defp effective(record), do: Map.take(record, [:hours, :reason])
  defp result(:clear, %{override: nil}, _), do: :absent
  defp result(:clear, _, _), do: :cleared
  defp result(_, _, override), do: override

  defp persist(state, next, id, changed?, result) do
    case Store.write(next) do
      :ok ->
        next = %{next | health: Store.healthy(next.generation)}

        if changed?, do: broadcast(next, [id])

        {:reply, {:ok, result}, next}

      {:error, _} ->
        {:reply, {:error, :write_failed}, state}
    end
  end

  defp broadcast(state, changed) do
    if Process.whereis(Aiur.PubSub),
      do: Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, {:build_estimates_changed, %{generation: state.generation, changed: changed}})
  end

  defp all_overrides(state), do: Map.new(for {id, %{override: o}} <- state.tickets, o != nil, do: {id, o})
end
