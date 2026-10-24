defmodule Aiur.Orchestrator.RateLimitFallback.PausedFallback do
  @moduledoc false

  alias Aiur.{CodingAgent, Issue, ModelAvailability}
  alias Aiur.Orchestrator.State

  @wait_seconds 600

  # The backend that actually hit the limit. The issue's current route may
  # already point elsewhere (an operator added a fallback route after the pause).
  @spec limited_backend(map(), Issue.t(), keyword()) :: String.t()
  def limited_backend(entry, issue, opts) do
    Keyword.get(opts, :current_backend) || get_in(entry, [:session_execution, :backend]) ||
      get_in(entry, [:usage_limit_session, :backend]) || CodingAgent.backend_for(issue)
  end

  # The complexity route, when it leads away from the limited backend. Moving
  # there needs no fallback labels: a fresh dispatch already resolves to it.
  @spec route_backend(Issue.t(), String.t(), keyword()) :: String.t() | nil
  def route_backend(issue, current_backend, opts) do
    route = Keyword.get_lazy(opts, :routing_backend, fn -> CodingAgent.routing_backend(issue) end)
    if is_binary(route) and route != current_backend, do: route
  end

  @spec backend(Issue.t(), String.t(), String.t() | nil, keyword()) :: String.t() | nil
  def backend(issue, current_backend, configured_fallback, opts),
    do: route_backend(issue, current_backend, opts) || configured_fallback

  @spec eligible?(map(), Issue.t(), String.t(), String.t() | nil, String.t(), keyword()) :: boolean()
  def eligible?(entry, issue, current_backend, fallback_backend, primary_backend, opts) do
    State.paused_running_entry?(entry) and
      Map.get(entry, :paused_reason) == :usage_limit_exhausted and
      wait_elapsed?(entry, opts) and
      fallback_target_usable?(fallback_backend, current_backend, issue, opts) and
      (current_backend == primary_backend or is_binary(route_backend(issue, current_backend, opts)))
  end

  # A paused entry that is ready to move but found the fleet full keeps this
  # mark until its next evaluation, so new dispatch leaves it the next free
  # slot (`Slots.dispatch_slots_available?/2`).
  @spec mark_slot_wait(State.t(), term(), boolean()) :: State.t()
  def mark_slot_wait(%State{} = state, issue_id, waiting?) do
    case Map.get(state.running, issue_id) do
      %{} = entry when waiting? -> put_entry(state, issue_id, Map.put(entry, :awaiting_fleet_slot, true))
      %{awaiting_fleet_slot: _} = entry -> put_entry(state, issue_id, Map.delete(entry, :awaiting_fleet_slot))
      _ -> state
    end
  end

  defp put_entry(state, issue_id, entry), do: Aiur.Orchestrator.RateLimitFallback.put_running_entry(state, issue_id, entry)

  defp fallback_target_usable?(backend, current_backend, issue, opts) do
    is_binary(backend) and backend in CodingAgent.known_backends() and backend != current_backend and
      ModelAvailability.available?(backend, opts) and is_nil(CodingAgent.override_backend(issue))
  end

  defp wait_elapsed?(entry, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    wait_seconds = Keyword.get(opts, :paused_fallback_wait_seconds, @wait_seconds)

    case Map.get(entry, :paused_at) do
      %DateTime{} = paused_at -> DateTime.diff(now, paused_at, :second) >= wait_seconds
      _ -> true
    end
  end
end
