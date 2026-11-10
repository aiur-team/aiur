defmodule Aiur.Orchestrator.RateLimitFallback.PausedFallback do
  @moduledoc false

  alias Aiur.{CodingAgent, Config, Issue, ModelAvailability}
  alias Aiur.CodingAgent.CapacityGate
  alias Aiur.Orchestrator.{RateLimitFallback, State}

  @wait_seconds 600

  # The backend that actually hit the limit. The issue's current route may
  # already point elsewhere (an operator added a fallback route after the pause).
  @spec limited_backend(map(), Issue.t(), keyword()) :: String.t()
  def limited_backend(entry, issue, opts) do
    Keyword.get(opts, :current_backend) || get_in(entry, [:session_execution, :backend]) ||
      get_in(entry, [:usage_limit_session, :backend]) || CodingAgent.backend_for(issue)
  end

  # The complexity route, when it leads away from the limited backend and the
  # capacity policy allows it, or else for a backend other than the primary the
  # next policy-allowed `agent.priority` backend (#7879, #7891). Moving there
  # needs no fallback labels: a fresh dispatch already resolves to it.
  @spec route_backend(Issue.t(), String.t(), keyword()) :: String.t() | nil
  def route_backend(issue, current_backend, opts) do
    route = Keyword.get_lazy(opts, :routing_backend, fn -> CodingAgent.routing_backend(issue) end)
    route = if is_binary(route) and route != current_backend, do: next_allowed([route], current_backend, opts)

    cond do
      is_binary(route) -> route
      current_backend != primary(opts) -> next_allowed(priority(opts), current_backend, opts)
      true -> nil
    end
  end

  # A claim on the primary prefers the configured fallback, then the rest of
  # `agent.priority`, whichever the policy allows; `""` still disables it.
  @spec backend(Issue.t(), String.t(), String.t() | nil, keyword()) :: String.t() | nil
  def backend(issue, current_backend, configured_fallback, opts) do
    cond do
      route = route_backend(issue, current_backend, opts) -> route
      current_backend == primary(opts) and configured_fallback not in [nil, ""] -> next_allowed([configured_fallback | priority(opts)], current_backend, opts)
      true -> nil
    end
  end

  # The first of `preferred` the capacity policy allows. The policy weighs every
  # priority backend together, so a last-resort source stays deferred while
  # another source is allowed.
  @spec next_allowed([String.t()], String.t(), keyword()) :: String.t() | nil
  def next_allowed(preferred, current_backend, opts) do
    known = CodingAgent.known_backends()
    allowed = (Enum.uniq(preferred ++ priority(opts)) -- [current_backend]) |> Enum.filter(&(&1 in known)) |> CapacityGate.allowed_routes(opts)
    Enum.find(preferred, &(&1 != current_backend and &1 in allowed))
  end

  defp priority(opts), do: Keyword.get_lazy(opts, :priority_backends, &Config.agent_priority_backends/0)
  defp primary(opts), do: Keyword.get_lazy(opts, :primary_backend, &Config.rate_limit_primary_backend/0)

  # The policy lookup runs last: it reads every account's meter.
  @spec eligible?(map(), Issue.t(), String.t(), String.t() | nil, keyword()) :: boolean()
  def eligible?(entry, issue, current_backend, configured_fallback, opts) do
    State.paused_running_entry?(entry) and
      Map.get(entry, :paused_reason) == :usage_limit_exhausted and
      wait_elapsed?(entry, opts) and is_nil(CodingAgent.override_backend(issue)) and
      fallback_target_usable?(backend(issue, current_backend, configured_fallback, opts), current_backend, opts)
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

  defp put_entry(state, issue_id, entry), do: RateLimitFallback.put_running_entry(state, issue_id, entry)

  defp fallback_target_usable?(backend, current_backend, opts) do
    is_binary(backend) and backend in CodingAgent.known_backends() and backend != current_backend and
      ModelAvailability.available?(backend, opts)
  end

  # A credit refusal does not reset on its own, so waiting gains nothing.
  defp wait_elapsed?(%{usage_limit_session: %{credit_limited: true}}, _opts), do: true

  defp wait_elapsed?(entry, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    wait_seconds = Keyword.get(opts, :paused_fallback_wait_seconds, @wait_seconds)

    case Map.get(entry, :paused_at) do
      %DateTime{} = paused_at -> DateTime.diff(now, paused_at, :second) >= wait_seconds
      _ -> true
    end
  end
end
