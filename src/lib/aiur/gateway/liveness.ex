defmodule Aiur.Gateway.Liveness do
  @moduledoc """
  Raises one `system.gateway.<id>.offline` attention per outage of a peer gateway.

  Store mode only: reads the shared instance roster every 30 s. A gateway is offline when its
  freshest instance heartbeat is older than `coordination.offline_after_seconds`. Only the
  repository leader alerts, so N observers raise one alert. Recovery closes the attention
  silently (`.resolved`, no push). Direct-hello detection (no store) is not built yet.
  """
  use GenServer

  alias Aiur.AlertFeed
  alias Aiur.Instance.Roster
  alias Aiur.Machine.Settings, as: MachineSettings

  @tick_ms 30_000

  @doc "Pure decision: `ages` is `%{gateway_id => age_ms}`, `alerted` the MapSet of open outages."
  @spec evaluate(%{String.t() => non_neg_integer()}, MapSet.t(), non_neg_integer()) :: {[tuple()], MapSet.t()}
  def evaluate(ages, alerted, threshold_ms) do
    actions =
      Enum.flat_map(ages, fn {id, age} ->
        cond do
          age > threshold_ms and not MapSet.member?(alerted, id) -> [{:alert, id, age}]
          age <= threshold_ms and MapSet.member?(alerted, id) -> [{:resolve, id}]
          true -> []
        end
      end)

    {actions, alerted}
  end

  @doc "Freshest heartbeat age per remote gateway; `nil` unless this daemon is the leader."
  @spec ages(map()) :: %{String.t() => non_neg_integer()} | nil
  def ages(%{instances: rows}) do
    if Enum.any?(rows, &(&1.current? and &1.leader? == true)) do
      rows
      |> Enum.reject(&(&1.current? or is_nil(&1.gateway_id)))
      |> Enum.group_by(& &1.gateway_id, & &1.age_ms)
      |> Map.new(fn {id, ages} -> {id, Enum.min(ages)} end)
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    send(self(), :tick)
    {:ok, %{alerted: nil, opts: opts}}
  end

  @impl true
  def handle_info(:tick, %{opts: opts} = state) do
    Process.send_after(self(), :tick, Keyword.get(opts, :tick_ms, @tick_ms))
    {:noreply, tick(state)}
  end

  @doc false
  @spec tick(map()) :: map()
  def tick(%{opts: opts} = state) do
    roster = Keyword.get(opts, :roster_fun, &Roster.list/0)

    with {:ok, view} <- roster.(), ages when is_map(ages) <- ages(view) do
      alerted = state.alerted || seed(Map.keys(ages), opts)
      {actions, alerted} = evaluate(ages, alerted, threshold_ms(opts))
      %{state | alerted: Enum.reduce(actions, alerted, &apply_action(&1, &2, opts))}
    else
      _ -> state
    end
  end

  # A daemon restart mid-outage must not re-alert: the ledger remembers open outages.
  defp seed(ids, opts) do
    state_fun = Keyword.get(opts, :condition_state_fun, &AlertFeed.condition_state/1)
    ids |> Enum.filter(&(state_fun.(topic(&1)) == :firing)) |> MapSet.new()
  end

  defp apply_action({:alert, id, age}, alerted, opts) do
    secs = div(age, 1000)

    case emit(opts).(topic(id),
           message: "Gateway #{id} silent for #{div(secs, 60)} min",
           reason: "no heartbeat for #{secs} s",
           needs_attention: true,
           severity: "warning",
           durable: true,
           central: true,
           exchange_payload: %{gateway_id: id, silent_ms: age, source: "store"}
         ) do
      :ok -> MapSet.put(alerted, id)
      _ -> alerted
    end
  end

  defp apply_action({:resolve, id}, alerted, opts) do
    case emit(opts).(topic(id) <> ".resolved", message: "Gateway #{id} is back", needs_attention: false, severity: "info", durable: true) do
      :ok -> MapSet.delete(alerted, id)
      _ -> alerted
    end
  end

  defp emit(opts), do: Keyword.get(opts, :emit, &Aiur.Signal.alert/2)
  defp topic(id), do: "system.gateway.#{id}.offline"

  defp threshold_ms(opts) do
    case Keyword.get(opts, :threshold_ms) do
      ms when is_integer(ms) ->
        ms

      nil ->
        case MachineSettings.get() do
          {:ok, %{coordination: %{offline_after_seconds: s}}} -> s * 1000
          _ -> 180_000
        end
    end
  end
end
