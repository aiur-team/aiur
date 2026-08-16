defmodule Aiur.Executor.TakeoverAlert.Monitor do
  @moduledoc """
  Periodic Executor takeover advisory monitor (#1182).

  Every `interval_ms` the monitor enumerates nonterminal tickets in the
  configured run scope, computes each ticket's durable convergence age, and
  emits an advisory `needs_attention` alert through the Executor-visible alert
  path (`aiurdev alerts --needs-attention`) once the first threshold is
  crossed, then again at the continuous cadence while the ticket remains
  nonterminal and unresolved.

  The monitor is advisory only: it never performs a takeover itself.

  Clock, ticket snapshot, PR evidence, thresholds and alert emission are
  injectable so the full boundary/cadence/restart behavior is testable with an
  injected clock and no real application or tracker.
  """

  use GenServer

  require Logger

  alias Aiur.Alerts
  alias Aiur.Config
  alias Aiur.Executor.TakeoverAlert
  alias Aiur.Executor.TakeoverAlert.{Snapshot, Store}
  alias Aiur.Issue

  @default_interval_ms :timer.minutes(5)
  # Re-fetch open-PR evidence no more often than this, regardless of a tighter
  # continuous cadence, so already-alerted tickets do not hammer the tracker.
  @min_pr_refresh_hours 1
  # Refresh open-PR evidence when a ticket's local anchor age is this close to
  # the first threshold, so the first alert carries fresh evidence.
  @pr_margin_hours 1
  # A tracked ticket absent from the snapshot for at least this long is treated
  # as out of the run scope: its active advisory is resolved and its state is
  # forgotten. Hours, not one tick, so a transient gap (daemon boot, orchestrator
  # restart) never resets a convergence clock.
  @scope_grace_hours 2

  @type state :: %{
          interval_ms: pos_integer(),
          store: GenServer.server(),
          snapshot_fun: (DateTime.t() -> [map()]),
          pr_fetch_fun: (map() -> map() | nil),
          now_fun: (-> DateTime.t()),
          settings_fun: (-> TakeoverAlert.thresholds()),
          alert_emitter: (map() -> term()),
          resolution_emitter: (map() -> term()),
          start_paused?: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      store: Keyword.get(opts, :store, Store),
      snapshot_fun: Keyword.get(opts, :snapshot_fun, &Snapshot.fetch/1),
      pr_fetch_fun: Keyword.get(opts, :pr_fetch_fun, &Snapshot.fetch_open_pr/1),
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
      settings_fun: Keyword.get(opts, :settings_fun, &settings/0),
      alert_emitter: Keyword.get(opts, :alert_emitter, &emit_alert/1),
      resolution_emitter: Keyword.get(opts, :resolution_emitter, &emit_resolution/1),
      start_paused?: Keyword.get(opts, :start_paused?, false)
    }

    unless state.start_paused?, do: schedule_tick(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run_tick(state)
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  @doc false
  @spec settings() :: TakeoverAlert.thresholds()
  def settings do
    %{
      first_hours: Config.executor_takeover_first_alert_hours(),
      continuous_hours: Config.executor_takeover_continuous_alert_hours()
    }
  end

  defp run_tick(state) do
    run_tick_inner(state)
  rescue
    error ->
      Logger.warning("executor_takeover tick raised: #{Exception.message(error)}")
      Logger.flush()
  catch
    kind, reason ->
      Logger.warning("executor_takeover tick caught #{kind}: #{inspect(reason)}")
      Logger.flush()
  end

  defp run_tick_inner(state) do
    thresholds = state.settings_fun.()
    now = state.now_fun.()
    tickets = state.snapshot_fun.(now)

    Enum.each(tickets, fn ticket ->
      process_ticket(state, ticket, thresholds, now)
    end)

    reconcile_out_of_scope(state, tickets, now)
    :ok
  end

  # A ticket the monitor previously tracked but that has now disappeared from
  # the snapshot (terminal or out of run scope) is resolved and forgotten once
  # it has been absent long enough that a transient gap can be ruled out. This
  # is what stops continuous alerts when a ticket leaves the configured run
  # scope without first being observed as terminal.
  defp reconcile_out_of_scope(state, tickets, now) do
    seen = MapSet.new(tickets, &Map.fetch!(&1, :identifier))

    state.store
    |> Store.identifiers()
    |> Enum.reject(&MapSet.member?(seen, &1))
    |> Enum.each(fn identifier ->
      absent_hours =
        case Store.last_seen_at(identifier, state.store) do
          %DateTime{} = last_seen -> TakeoverAlert.age_hours(last_seen, now)
          _other -> @scope_grace_hours
        end

      if absent_hours >= @scope_grace_hours do
        resolve_if_active(state, identifier, now)
      end
    end)
  end

  defp process_ticket(state, ticket, thresholds, now) do
    identifier = Map.fetch!(ticket, :identifier)

    if Map.get(ticket, :terminal?) or not Map.get(ticket, :in_scope?, true) do
      resolve_if_active(state, identifier, now)
    else
      handle_active_ticket(state, ticket, identifier, thresholds, now)
    end
  end

  defp handle_active_ticket(state, ticket, identifier, thresholds, now) do
    if thresholds.first_hours <= 0 do
      # Alert disabled by config: resolve any previously-active advisory so a
      # disabled setting is not a silent kill switch that leaves a stale
      # needs-attention alert in the feed.
      resolve_if_active(state, identifier, now)
    else
      record = Store.observe(identifier, Map.get(ticket, :live_owner?, false), now, state.store)
      record = maybe_refresh_pr(state, ticket, identifier, record, thresholds, now)
      pr_created = get_in(record, [:pr, :created_at])
      anchor = TakeoverAlert.effective_anchor(record.anchor_at, pr_created)
      age = TakeoverAlert.age_hours(anchor, now)

      case TakeoverAlert.decide(thresholds, age, record.last_alert_at, now) do
        :alert ->
          emit_alert(state, ticket, record, anchor, age, thresholds, now)
          Store.record_alert(identifier, now, state.store)
          :ok

        _ ->
          :ok
      end
    end
  end

  defp maybe_refresh_pr(state, ticket, identifier, record, thresholds, now) do
    first_hours = thresholds.first_hours
    local_age = TakeoverAlert.age_hours(record.anchor_at, now)
    already_alerted? = record.last_alert_at != nil

    candidate? =
      record.pr_checked_at == nil or already_alerted? or local_age >= first_hours - @pr_margin_hours

    if candidate? and pr_stale?(record, now, thresholds.continuous_hours) do
      enrich_ticket =
        if already_alerted?, do: Map.put(ticket, :enrich_ci?, true), else: ticket

      pr = safely_fetch_pr(state.pr_fetch_fun, enrich_ticket)
      Store.record_pr(identifier, pr, now, state.store)
    else
      record
    end
  end

  defp pr_stale?(record, now, continuous_hours) do
    case record.pr_checked_at do
      nil ->
        true

      %DateTime{} = checked_at ->
        TakeoverAlert.age_hours(checked_at, now) >= max(continuous_hours, @min_pr_refresh_hours)
    end
  end

  defp safely_fetch_pr(pr_fetch_fun, ticket) do
    pr_fetch_fun.(ticket)
  rescue
    error ->
      Logger.warning("executor_takeover pr_fetch failed: #{Exception.message(error)}")
      nil
  catch
    kind, reason ->
      Logger.warning("executor_takeover pr_fetch caught #{kind}: #{inspect(reason)}")
      nil
  end

  defp emit_alert(state, ticket, record, anchor, age, thresholds, now) do
    evidence = %{
      identifier: Map.fetch!(ticket, :identifier),
      title: Map.get(ticket, :title),
      url: Map.get(ticket, :url),
      age_hours: age,
      anchor: anchor,
      now: now,
      first_hours: thresholds.first_hours,
      continuous_hours: thresholds.continuous_hours,
      repeated?: record.last_alert_at != nil,
      live_owner?: Map.get(ticket, :live_owner?, false),
      dispatches: record.dispatches,
      pr: record.pr
    }

    state.alert_emitter.(%{
      identifier: evidence.identifier,
      evidence: evidence,
      ticket: ticket
    })
  end

  defp resolve_if_active(state, identifier, now) do
    case Store.forget(identifier, state.store) do
      {:ok, true} ->
        state.resolution_emitter.(%{identifier: identifier, now: now})
        :ok

      {:ok, false} ->
        :ok
    end
  end

  defp emit_alert(%{identifier: identifier, evidence: evidence}) do
    Alerts.emit_system(TakeoverAlert.topic(identifier),
      message: TakeoverAlert.message(evidence),
      issue: %Issue{identifier: identifier},
      reason: "Executor takeover advisory for ##{identifier}.",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp emit_resolution(%{identifier: identifier}) do
    Alerts.emit_system(TakeoverAlert.resolution_topic(identifier),
      message: "Executor takeover advisory resolved: ##{identifier} is terminal or out of run scope.",
      issue: %Issue{identifier: identifier},
      reason: "Executor takeover advisory resolved.",
      needs_attention: false,
      severity: "info"
    )
  end

  defp schedule_tick(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :tick, interval_ms)
  end
end
