defmodule Aiur.Orchestrator.DispatchPolicy.Eligibility do
  @moduledoc """
  Per-issue eligibility predicates: state slots, authorization, and dependency holds. Public API stays on `Aiur.Orchestrator.DispatchPolicy`.
  """

  import Aiur.Orchestrator.DispatchPolicy.IssueStates

  alias Aiur.{Config, Issue}
  alias Aiur.Orchestrator.{Slots, State}

  # Kept as the pre-#2751 phrasing for the shapes that carry no nameable
  # blocker, so an unreadable hold still reads as a hold.
  @unknown_dependency_hold "blocked by a non-terminal dependency"

  @spec state_slots_available?(term(), term()) :: boolean()
  def state_slots_available?(%Issue{state: issue_state}, %State{} = state) do
    limit = effective_state_limit(issue_state, state)
    used = running_issue_count_for_state(state.running, issue_state)
    limit > used
  end

  def state_slots_available?(_issue, _state), do: false

  # Per-state cap honors explicit overrides in
  # `agent.max_concurrent_agents_by_state` first, then falls back to the
  # *session-aware* global limit. Without this, bumping the global cap at
  # runtime (←/→ in the agent list) had no effect on dispatch eligibility
  # because the per-state default was pinned to the workflow file value.
  @spec effective_state_limit(term(), State.t()) :: pos_integer()
  def effective_state_limit(issue_state, %State{} = state) do
    config = Config.settings!()
    normalized = normalize_issue_state(issue_state)

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      normalized,
      Slots.max_concurrent_agent_limit(state)
    )
  end

  @spec running_issue_count_for_state(term(), term()) :: non_neg_integer()
  def running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}} = entry} ->
        normalize_issue_state(state_name) == normalized_state and
          State.active_running_entry?(entry)

      _ ->
        false
    end)
  end

  @spec issue_not_paused?(Issue.t()) :: boolean()
  def issue_not_paused?(%Issue{} = issue), do: not Issue.paused?(issue)

  @spec issue_not_parked?(Issue.t()) :: boolean()
  def issue_not_parked?(%Issue{} = issue), do: not Issue.parked?(issue)

  @spec issue_routable_to_worker?(term()) :: boolean()
  def issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
      when is_boolean(assigned_to_worker),
      do: assigned_to_worker

  def issue_routable_to_worker?(_issue), do: true

  @spec issue_dispatch_authorized?(term()) :: boolean()
  def issue_dispatch_authorized?(%Issue{dispatch_authorized?: authorized?})
      when is_boolean(authorized?), do: authorized?

  def issue_dispatch_authorized?(_issue), do: false

  # A deferred authorization (a transient budget hold / rate limit / transport
  # failure prevented the provenance fetch) is distinct from a verified denial.
  # Dispatch still skips the ticket this cycle (fail-closed), but the
  # orchestrator must never read `:deferred` as revocation — that would kill a
  # running agent over a 30-second throttle (#2409).
  @spec issue_dispatch_authorization_deferred?(term()) :: boolean()
  def issue_dispatch_authorization_deferred?(%Issue{dispatch_authorization: :deferred}), do: true
  def issue_dispatch_authorization_deferred?(_issue), do: false

  @spec todo_issue_blocked_by_non_terminal?(term(), MapSet.t()) :: boolean()
  def todo_issue_blocked_by_non_terminal?(
        %Issue{state: issue_state, blocked_by: blockers},
        terminal_states
      )
      when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, &non_terminal_blocker?(&1, terminal_states))
  end

  def todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  @doc """
  The `blocked_by` entries actually holding the issue: those whose state is not
  terminal, plus any entry carrying no readable state (fail-closed, exactly as
  the gate treats them).
  """
  @spec non_terminal_blockers(term(), MapSet.t()) :: [term()]
  def non_terminal_blockers(%Issue{blocked_by: blockers}, terminal_states)
      when is_list(blockers) do
    Enum.filter(blockers, &non_terminal_blocker?(&1, terminal_states))
  end

  def non_terminal_blockers(_issue, _terminal_states), do: []

  @doc """
  Human-readable reason for a dependency hold, naming only the blockers that
  cause it.

  The dispatch log line used to `inspect/1` the whole `blocked_by` list, so a
  hold whose list happened to lead with a terminal blocker read as though a
  closed issue were blocking dispatch, and the one open blocker that mattered
  was invisible unless the reader dumped the list (#2751).
  """
  @spec describe_dependency_hold(term(), MapSet.t()) :: String.t()
  def describe_dependency_hold(%Issue{blocked_by: blockers} = issue, terminal_states)
      when is_list(blockers) do
    holding = non_terminal_blockers(issue, terminal_states)
    describe_hold(holding, length(blockers) - length(holding))
  end

  def describe_dependency_hold(_issue, _terminal_states), do: @unknown_dependency_hold

  defp non_terminal_blocker?(%{state: blocker_state}, terminal_states)
       when is_binary(blocker_state),
       do: !terminal_issue_state?(blocker_state, terminal_states)

  defp non_terminal_blocker?(_blocker, _terminal_states), do: true

  # Only ever reachable if a caller describes an issue that is not actually
  # held; the gate itself never produces an empty holding list here.
  defp describe_hold([], _ignored), do: @unknown_dependency_hold

  defp describe_hold(holding, ignored) do
    noun = if length(holding) == 1, do: "dependency", else: "dependencies"

    "blocked by open #{noun} " <>
      Enum.map_join(holding, ", ", &blocker_label/1) <> ignored_suffix(ignored)
  end

  defp ignored_suffix(count) when is_integer(count) and count > 0 do
    noun = if count == 1, do: "terminal dependency", else: "terminal dependencies"
    "; #{count} #{noun} ignored"
  end

  defp ignored_suffix(_count), do: ""

  defp blocker_label(%{identifier: identifier} = blocker)
       when is_binary(identifier) and identifier != "" do
    "#{issue_number_sigil(identifier)}#{identifier} (#{blocker_state_label(blocker)})"
  end

  defp blocker_label(blocker), do: inspect(blocker)

  defp blocker_state_label(%{state: state}) when is_binary(state) and state != "", do: state
  defp blocker_state_label(_blocker), do: "unknown state"

  defp issue_number_sigil(identifier) do
    if Regex.match?(~r/\A\d+\z/, identifier), do: "#", else: ""
  end

  @doc """
  True when dispatch of the issue must be held for an open blocking Command,
  per the latest dispatch cycle's decision-store read.

  `blocked_ticket_ids` is a `MapSet` of ticket identifiers with open blocking
  Commands. The gate is fail-closed: `:unavailable` (the decision store could
  not be read) returns true, because an open blocking Command is
  indistinguishable from an empty store when the store cannot be read.
  `nil` (no cycle computed the set) returns false, preserving compatibility
  before the dispatcher has refreshed the store snapshot.

  The Reconciler must NOT call this directly for its running-agent guard: it
  deliberately fails OPEN there (stopping healthy running agents on a store
  outage would be worse than letting a blocked agent run one more cycle), so
  it checks `MapSet` membership explicitly.
  """
  @spec blocked_on_decision?(Issue.t(), MapSet.t() | :unavailable | nil) :: boolean()
  def blocked_on_decision?(%Issue{id: id}, %MapSet{} = blocked),
    do: MapSet.member?(blocked, id)

  def blocked_on_decision?(_issue, :unavailable), do: true
  def blocked_on_decision?(_issue, _blocked), do: false
end
