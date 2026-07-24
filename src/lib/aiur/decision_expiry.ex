defmodule Aiur.DecisionExpiry do
  @moduledoc """
  Retires open Decisions after their owning ticket leaves the live agent set.

  The grace period protects Decisions created around agent startup and shutdown
  races. Liveness lookup failures skip the entire sweep so a transient
  Orchestrator outage can never be mistaken for an empty run.
  """

  use GenServer

  require Logger

  alias Aiur.DecisionStore

  @interval_ms 60_000
  @grace_seconds 300
  @reason_class "agent_not_running"
  @orchestrator_timeout 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec sweep(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep(opts \\ []) do
    with {:ok, active_identifiers} <- active_identifiers(opts),
         {:ok, decisions} <- decisions(opts) do
      active = MapSet.new(active_identifiers)
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      grace_seconds = Keyword.get(opts, :grace_seconds, @grace_seconds)

      expired_count =
        decisions
        |> Enum.filter(&expired_candidate?(&1, active, now, grace_seconds))
        |> Enum.count(&expire(&1, now, opts))

      {:ok, expired_count}
    end
  end

  @impl true
  def init(opts) do
    state = %{opts: opts, interval_ms: Keyword.get(opts, :interval_ms, @interval_ms)}
    schedule_sweep(Keyword.get(opts, :initial_delay_ms, state.interval_ms))
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    case sweep(state.opts) do
      {:ok, count} when count > 0 ->
        Logger.info("aiur_decision_expiry expired_count=#{count}")

      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning("aiur_decision_expiry sweep_skipped reason=#{inspect(reason)}")
    end

    schedule_sweep(state.interval_ms)
    {:noreply, state}
  end

  defp active_identifiers(opts) do
    case Keyword.get(opts, :active_identifiers_fun) do
      fun when is_function(fun, 0) -> fun.()
      nil -> fetch_active_identifiers()
    end
  end

  defp fetch_active_identifiers do
    try do
      {:ok, GenServer.call(Aiur.Orchestrator, :list_active_identifiers, @orchestrator_timeout)}
    catch
      :exit, reason -> {:error, {:orchestrator_unavailable, reason}}
    end
  end

  defp decisions(opts) do
    case Keyword.get(opts, :decisions_fun) do
      fun when is_function(fun, 0) -> fun.()
      nil -> fetch_decisions()
    end
  end

  defp fetch_decisions do
    try do
      {:ok, DecisionStore.list()}
    catch
      :exit, reason -> {:error, {:decision_store_unavailable, reason}}
    end
  end

  defp expired_candidate?(decision, active, now, grace_seconds) do
    decision.decision_status == :open and
      not MapSet.member?(active, decision.ticket.identifier) and
      DateTime.diff(now, decision.created_at, :second) >= grace_seconds
  end

  defp expire(decision, now, opts) do
    result =
      case Keyword.get(opts, :expire_fun) do
        fun when is_function(fun, 3) -> fun.(decision.decision_id, @reason_class, now)
        nil -> DecisionStore.expire(decision.decision_id, @reason_class, now: now)
      end

    match?({:ok, %{status: status}} when status in [:accepted, :duplicate], result)
  end

  defp schedule_sweep(delay_ms), do: Process.send_after(self(), :sweep, delay_ms)
end
