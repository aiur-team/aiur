defmodule AiurWeb.OperatorControlCenter.PayloadLoader do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Aiur.PollCadence
  alias AiurWeb.{ControlCenterCache, ControlCenterPresenter, Endpoint}
  alias AiurWeb.OperatorControlCenter.{DecisionProvider, TicketsPresenter, UnitsPresenter}

  @reload_debounce_ms 50
  @reload_min_interval_ms 400
  @max_reload_events 32

  @spec load(:cached | :fresh | {:event, MapSet.t()}) :: map()
  def load(mode \\ :cached)

  def load(mode) when mode in [:cached, :fresh] do
    do_load(mode)
  end

  def load({:event, %MapSet{}} = mode), do: do_load(mode)

  defp do_load(mode) do
    providers = providers()

    case cache_server() do
      false -> load_uncached(providers)
      server -> fetch_cached(server, mode, providers)
    end
  end

  @spec detail(String.t() | nil) :: {:ok, map()} | {:error, term()} | :none
  def detail(nil), do: :none

  def detail(decision_id) when is_binary(decision_id) do
    {_orchestrator, decision_store, decision_metrics, _recent_merge_store, _snapshot_timeout_ms} = providers()

    DecisionProvider.detail(decision_id,
      decision_store: decision_store,
      decision_metrics: decision_metrics
    )
  end

  def detail(_decision_id), do: {:error, :not_found}

  @spec decisions(map()) :: {:ok, map()} | {:error, term()}
  def decisions(params) when is_map(params) do
    {_orchestrator, decision_store, decision_metrics, _recent_merge_store, _snapshot_timeout_ms} = providers()

    DecisionProvider.list(params,
      decision_store: decision_store,
      decision_metrics: decision_metrics
    )
  end

  def decisions(_params), do: {:error, {:invalid_query, {:params, :invalid_type}}}

  @spec mark_loaded(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def mark_loaded(socket) do
    socket
    |> assign(:payload_loaded_at_ms, now_ms())
    |> assign(:payload_reload_scheduled?, false)
    |> assign(:payload_reload_mode, :cached)
  end

  @spec schedule(Phoenix.LiveView.Socket.t(), :cached | {:event, term()}) :: Phoenix.LiveView.Socket.t()
  def schedule(socket, mode \\ :cached)

  def schedule(%{assigns: %{payload_reload_scheduled?: true}} = socket, {:event, event_key}),
    do: assign(socket, :payload_reload_mode, merge_event_mode(socket, event_key))

  def schedule(%{assigns: %{payload_reload_scheduled?: true}} = socket, _mode), do: socket

  def schedule(socket, :cached), do: schedule_reload(socket, :cached)

  def schedule(socket, {:event, event_key}),
    do: schedule_reload(socket, initial_reload_mode({:event, event_key}))

  defp schedule_reload(socket, mode) do
    last_loaded_at_ms = Map.get(socket.assigns, :payload_loaded_at_ms, now_ms() - @reload_min_interval_ms)
    elapsed_ms = max(now_ms() - last_loaded_at_ms, 0)
    delay_ms = max(@reload_min_interval_ms - elapsed_ms + @reload_debounce_ms, @reload_debounce_ms)

    schedule_reload(delay_ms)

    socket
    |> assign(:payload_reload_scheduled?, true)
    |> assign(:payload_reload_mode, mode)
  end

  defp fetch_cached(server, {:event, %MapSet{} = events}, providers) do
    event_key = events |> MapSet.to_list() |> Enum.sort()

    ControlCenterCache.fetch_event(
      server,
      cache_key(providers),
      event_key,
      fn -> load_uncached(providers) end
    )
  catch
    :exit, _reason -> load_uncached(providers)
  end

  defp fetch_cached(server, mode, providers) do
    max_age_ms = if mode == :fresh, do: 0, else: @reload_min_interval_ms

    ControlCenterCache.fetch(
      server,
      cache_key(providers),
      max_age_ms,
      fn -> load_uncached(providers) end
    )
  catch
    :exit, _reason -> load_uncached(providers)
  end

  defp initial_reload_mode({:event, event_key}), do: {:event, MapSet.new([event_key])}

  defp merge_event_mode(socket, event_key) do
    case Map.get(socket.assigns, :payload_reload_mode) do
      {:event, %MapSet{} = events} -> {:event, events |> MapSet.put(event_key) |> bound_reload_events()}
      _mode -> {:event, MapSet.new([event_key])}
    end
  end

  defp bound_reload_events(events) do
    events
    |> MapSet.to_list()
    |> Enum.sort(:desc)
    |> Enum.take(@max_reload_events)
    |> MapSet.new()
  end

  defp load_uncached({orchestrator, decision_store, decision_metrics, recent_merge_store, snapshot_timeout_ms}) do
    payload =
      ControlCenterPresenter.state_payload(
        orchestrator,
        snapshot_timeout_ms,
        [
          decision_store: decision_store,
          decision_metrics: decision_metrics,
          recent_merge_store: recent_merge_store
        ]
        |> maybe_put_option(:fleet_fun, Endpoint.config(:units_fleet_fun))
      )

    retained_counts = retained_counts(decision_store)

    payload
    |> Map.put(:retained_counts, retained_counts)
    |> update_in([:provider_health], &Map.put(&1, :retained_counts, retained_counts.health.status))
    |> then(&Map.put(&1, :units, UnitsPresenter.load(&1, units_options())))
    |> Map.put(:tickets, TicketsPresenter.load(tickets_options()))
  end

  defp providers do
    {
      Endpoint.config(:orchestrator) || Aiur.Orchestrator,
      Endpoint.config(:decision_store) || Aiur.DecisionStore,
      Endpoint.config(:decision_metrics) || Aiur.DecisionMetrics,
      Endpoint.config(:recent_merge_store) || Aiur.RecentMergeStore,
      PollCadence.snapshot_tolerance_ms(Endpoint.config(:snapshot_timeout_ms) || 15_000, class: :dispatch)
    }
  end

  defp cache_key({orchestrator, decision_store, decision_metrics, recent_merge_store, snapshot_timeout_ms}) do
    {
      provider_identity(orchestrator),
      provider_identity(decision_store),
      provider_identity(decision_metrics),
      provider_identity(recent_merge_store),
      snapshot_timeout_ms
    }
  end

  defp units_options do
    []
    |> maybe_put_option(:membership_fun, Endpoint.config(:units_membership_fun))
    |> maybe_put_option(:activity_fun, Endpoint.config(:units_activity_fun))
  end

  defp tickets_options do
    maybe_put_option([], :tickets_fun, Endpoint.config(:open_tickets_fun))
  end

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp provider_identity(server) do
    {server, GenServer.whereis(server) || :unavailable}
  rescue
    _error -> {server, :unavailable}
  catch
    :exit, _reason -> {server, :unavailable}
  end

  defp cache_server do
    case Endpoint.config(:control_center_cache) do
      false -> false
      nil -> ControlCenterCache
      server -> server
    end
  end

  defp schedule_reload(delay_ms) do
    case Endpoint.config(:control_center_reload_timer) do
      timer when is_function(timer, 3) -> timer.(self(), :reload_payload, delay_ms)
      _other -> Process.send_after(self(), :reload_payload, delay_ms)
    end
  end

  defp retained_counts(decision_store) do
    {:ok, counts} = DecisionProvider.counts(decision_store: decision_store)
    counts
  rescue
    _error -> unavailable_retained_counts()
  catch
    :exit, _reason -> unavailable_retained_counts()
  end

  defp unavailable_retained_counts do
    %{
      open: nil,
      blocking: nil,
      total: nil,
      awaiting: nil,
      awaiting_blocking: nil,
      deferred: nil,
      scope: %{kind: :retained, label: "All retained decisions"},
      health: %{
        status: :unavailable,
        partial?: true,
        reason: :retained_store_unavailable,
        label: "Command counts unavailable"
      }
    }
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
