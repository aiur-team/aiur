defmodule Aiur.Orchestrator.State.RunningEntries do
  @moduledoc false
  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.Orchestrator.{CiLifecycle, State}

  @spec find_issue_id_for_ref(map(), term()) :: term() | nil
  def find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  @spec running_entry_session_id(term()) :: String.t()
  def running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  def running_entry_session_id(_running_entry), do: "n/a"

  @spec issue_context(Issue.t()) :: String.t()
  def issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  @spec active_running_count(term()) :: non_neg_integer()
  def active_running_count(running) when is_map(running) do
    Enum.count(running, fn
      {_issue_id, entry} -> active_running_entry?(entry)
    end)
  end

  def active_running_count(_running), do: 0

  @spec paused_running_count(term()) :: non_neg_integer()
  def paused_running_count(running) when is_map(running) do
    Enum.count(running, fn
      {_issue_id, entry} -> paused_running_entry?(entry)
    end)
  end

  def paused_running_count(_running), do: 0

  # Paused entries that keep their fleet reservation. A deliberate/Executor
  # pause holds its slot so the polling loop cannot auto-claim replacement
  # work. CI-wait, dependency-blocked, and duration-capped pauses are the
  # exception: the daemon owns that wait (or the agent has simply hit its time
  # cap and is parked for review), so the parked runner releases normal
  # dispatch capacity — holding the slot would convert the time cap into a
  # capacity leak where parked agents accumulate against the fleet limit
  # (#2329).
  # A provider usage limit belongs here for the same reason: the account, not
  # this agent, is what the fleet waits on. Any pause on a `ci-wait` ticket
  # releases too: its PR is handed off and the daemon owns that wait (#4694).
  @non_reserving_pause_reasons [:ci_wait, :blocker_dependency, :optimistic_blocker_failed, :max_agent_duration, :usage_limit_exhausted]

  @spec non_reserving_pause_reason?(term()) :: boolean()
  def non_reserving_pause_reason?(reason), do: reason in @non_reserving_pause_reasons

  @spec reserved_paused_running_count(term()) :: non_neg_integer()
  def reserved_paused_running_count(running) when is_map(running) do
    Enum.count(running, fn
      {_issue_id, %{paused_reason: reason}} when reason in @non_reserving_pause_reasons -> false
      {_issue_id, entry} -> paused_running_entry?(entry) and not CiLifecycle.ci_wait_state?(get_in(entry, [:issue, Access.key(:state)]))
    end)
  end

  def reserved_paused_running_count(_running), do: 0

  @spec active_running_entry?(term()) :: boolean()
  def active_running_entry?(entry) when is_map(entry) do
    not (completed_running_entry?(entry) or paused_running_entry?(entry) or
           deactivated_running_entry?(entry) or error_running_entry?(entry))
  end

  def active_running_entry?(_entry), do: false
  @spec paused_running_entry?(term()) :: boolean()
  def paused_running_entry?(entry) when is_map(entry) do
    (get_in(entry, [:control, :status]) || :working) == :paused
  end

  def paused_running_entry?(_entry), do: false

  @spec error_running_entry?(term()) :: boolean()
  def error_running_entry?(entry) when is_map(entry) do
    (get_in(entry, [:control, :status]) || :working) == :error
  end

  def error_running_entry?(_entry), do: false

  @spec sleeping_running_entry?(term()) :: boolean()
  def sleeping_running_entry?(entry) when is_map(entry) do
    (get_in(entry, [:control, :status]) || :working) == :sleeping
  end

  def sleeping_running_entry?(_entry), do: false

  @spec completed_running_entry?(term()) :: boolean()
  def completed_running_entry?(entry) when is_map(entry) do
    get_in(entry, [:control, :status]) == :completed
  end

  def completed_running_entry?(_entry), do: false

  @spec completed_provenance?(term()) :: boolean()
  def completed_provenance?(entry) when is_map(entry) do
    completed_running_entry?(entry) or Map.get(entry, :completed_provenance) == true
  end

  def completed_provenance?(_entry), do: false

  @spec deactivated_running_entry?(term()) :: boolean()
  def deactivated_running_entry?(entry) when is_map(entry) do
    get_in(entry, [:control, :status]) == :deactivated
  end

  def deactivated_running_entry?(_entry), do: false

  @spec find_running_key_by_identifier(map(), String.t()) :: term() | nil
  def find_running_key_by_identifier(running, identifier) do
    Enum.find_value(running, fn
      {issue_id, %{identifier: id}} -> if to_string(id) == identifier, do: issue_id, else: nil
      _ -> nil
    end)
  end

  # Freeze the runtime clock while the agent is paused and shift
  # `started_at` forward on resume so `now - started_at` excludes the
  # paused interval. The age column in the agent list (and any other
  # consumer of `running_seconds/2`) stops advancing while paused.
  @spec apply_pause_runtime_clock(map(), atom(), atom(), term()) :: map()
  def apply_pause_runtime_clock(entry, :working, :paused, now) when is_map(entry) do
    Map.put(entry, :paused_at, now)
  end

  def apply_pause_runtime_clock(entry, :paused, :working, now) when is_map(entry) do
    shift_started_at_by_pause(entry, now)
  end

  def apply_pause_runtime_clock(entry, _previous, _next, _now), do: entry

  @spec thaw_pause_clock(map(), term(), atom(), term()) :: map()
  def thaw_pause_clock(running, issue_id, previous_status, now) when is_map(running) do
    case Map.get(running, issue_id) do
      nil ->
        running

      entry ->
        Map.put(running, issue_id, shift_started_at_by_pause_if(entry, previous_status, now))
    end
  end

  @spec shift_started_at_by_pause_if(map(), atom(), term()) :: map()
  def shift_started_at_by_pause_if(entry, :paused, now),
    do: shift_started_at_by_pause(entry, now)

  def shift_started_at_by_pause_if(entry, _previous, _now), do: entry

  # A duration-capped pause is owned by `reset_duration_clock_if_capped/4`
  # (Executor resume -> fresh budget, automated resume -> preserve overrun),
  # so the thaw must only un-freeze the pause clock (clear `paused_at`) and
  # must NOT credit the paused interval back into `started_at`. Crediting it
  # would advance `started_at` toward now and silently reset the overrun on
  # an automated resume — the exact #420 leak. Other pauses keep the normal
  # "exclude the paused interval" shift.
  @spec shift_started_at_by_pause(map(), term()) :: map()
  def shift_started_at_by_pause(%{paused_reason: :max_agent_duration} = entry, %DateTime{}) do
    Map.put(entry, :paused_at, nil)
  end

  def shift_started_at_by_pause(%{paused_at: %DateTime{} = paused_at} = entry, %DateTime{} = now) do
    paused_for = max(0, DateTime.diff(now, paused_at, :second))

    entry
    |> Map.update(:started_at, nil, fn
      %DateTime{} = started_at -> DateTime.add(started_at, paused_for, :second)
      other -> other
    end)
    |> Map.put(:paused_at, nil)
  end

  def shift_started_at_by_pause(entry, _now), do: entry

  @spec issue_tag(term()) :: String.t() | nil
  def issue_tag(%Issue{} = issue) do
    issue
    |> Issue.label_names()
    |> Enum.find(fn label -> is_binary(label) and String.starts_with?(label, "agent:") end)
  end

  def issue_tag(_issue), do: nil

  @spec find_running_by_identifier(map(), String.t()) :: map() | nil
  def find_running_by_identifier(running, issue_identifier) do
    Enum.find_value(running, fn
      {_issue_id, %{identifier: identifier} = entry} ->
        if to_string(identifier) == issue_identifier, do: entry, else: nil

      _ ->
        nil
    end)
  end

  @doc false
  @spec find_unique_running_by_identity(map(), TrackerIdentity.t()) ::
          {:ok, map(), String.t()} | {:error, :no_running_agent | :ambiguous_identifier}
  def find_unique_running_by_identity(running, %TrackerIdentity{} = identity) when is_map(running) do
    identity_key = TrackerIdentity.github_key(identity)

    exact_matches =
      Enum.flat_map(running, fn
        {_issue_id, entry} when is_map(entry) ->
          if running_identity_key(entry) == identity_key and not is_nil(identity_key), do: [entry], else: []

        _entry ->
          []
      end)

    case exact_matches do
      [entry] -> unique_identifier_target(running, entry)
      _matches -> {:error, if(exact_matches == [], do: :no_running_agent, else: :ambiguous_identifier)}
    end
  end

  def find_unique_running_by_identity(_running, _identity), do: {:error, :no_running_agent}

  defp unique_identifier_target(running, entry) do
    identifier = entry |> Map.get(:identifier) |> to_string()

    matches =
      Enum.count(running, fn
        {_issue_id, %{identifier: candidate}} -> to_string(candidate) == identifier
        _entry -> false
      end)

    if identifier != "" and matches == 1,
      do: {:ok, entry, identifier},
      else: {:error, :ambiguous_identifier}
  end

  defp running_identity_key(entry) do
    identity =
      Map.get(entry, :tracker_identity) ||
        case Map.get(entry, :issue) do
          %Issue{} = issue -> Issue.tracker_identity(issue)
          _issue -> nil
        end

    TrackerIdentity.github_key(identity)
  end

  @spec find_running_by_repl_pane_id(map(), term()) :: map() | nil
  def find_running_by_repl_pane_id(running, pane_id) do
    Enum.find_value(running, fn
      {_issue_id, %{repl_pane_id: ^pane_id} = entry} -> entry
      _ -> nil
    end)
  end

  @spec pop_running_entry(State.t(), term()) :: {term(), State.t()}
  def pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  @spec running_seconds(term(), term()) :: non_neg_integer()
  def running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  def running_seconds(_started_at, _now), do: 0

  # Wall-clock seconds the agent has spent *actively working*. If the
  # entry is currently paused, the clock is frozen at the moment of
  # pause; on resume `shift_started_at_by_pause/2` shifts `started_at`
  # forward so any future delta excludes the paused interval.
  @spec effective_runtime_seconds(term(), DateTime.t()) :: non_neg_integer()
  def effective_runtime_seconds(entry, %DateTime{} = now) when is_map(entry) do
    case {Map.get(entry, :started_at), Map.get(entry, :paused_at)} do
      {%DateTime{} = started_at, %DateTime{} = paused_at} ->
        running_seconds(started_at, paused_at)

      {started_at, _} ->
        running_seconds(started_at, now)
    end
  end

  def effective_runtime_seconds(_entry, _now), do: 0
  # --- Rework-attempt bound (#2422) ------------------------------------------
  #
  # The same head SHA must not re-enter `agent:rework` more than
  # `rework_attempt_limit/0` times: when rework completes and the gating signal
  # has not moved, the next routing is a stuck condition, and the bound raises
  # a single attention instead of looping. A new head SHA starts a fresh count,
  # so a genuine rework push is never affected. All helpers are nil-safe on the
  # head SHA — when the head cannot be read the bound is skipped rather than
  # refusing a rework the writer cannot key.

  @rework_attempt_limit 3

  @doc false
  @spec rework_attempt_limit() :: pos_integer()
  def rework_attempt_limit do
    case Application.get_env(:aiur, :rework_attempt_limit) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @rework_attempt_limit
    end
  end

  @doc false
  @spec rework_attempt_count(State.t(), String.t(), String.t() | nil) :: non_neg_integer()
  def rework_attempt_count(%State{} = state, issue_id, head_sha)
      when is_binary(issue_id) do
    if is_binary(head_sha) do
      Map.get(state.rework_attempts, {issue_id, head_sha}, 0)
    else
      0
    end
  end

  @doc false
  @spec rework_attempt_limit_reached?(State.t(), String.t(), String.t() | nil) :: boolean()
  def rework_attempt_limit_reached?(%State{} = state, issue_id, head_sha)
      when is_binary(issue_id) do
    rework_attempt_count(state, issue_id, head_sha) >= rework_attempt_limit()
  end

  @doc false
  # Records that the ticket was routed to rework for `head_sha`. Called by the
  # rework writers only after the `rework` write actually succeeded, so a failed
  # tracker write never consumes the bound.
  @spec bump_rework_attempt(State.t(), String.t(), String.t() | nil) :: State.t()
  def bump_rework_attempt(%State{} = state, issue_id, head_sha)
      when is_binary(issue_id) do
    if is_binary(head_sha) do
      count = rework_attempt_count(state, issue_id, head_sha)
      %{state | rework_attempts: Map.put(state.rework_attempts, {issue_id, head_sha}, count + 1)}
    else
      state
    end
  end

  @doc false
  @spec rework_attempt_alerted?(State.t(), String.t(), String.t()) :: boolean()
  def rework_attempt_alerted?(%State{} = state, issue_id, head_sha)
      when is_binary(issue_id) and is_binary(head_sha) do
    MapSet.member?(state.rework_attempt_alerted, {issue_id, head_sha})
  end

  @doc false
  @spec mark_rework_attempt_alerted(State.t(), String.t(), String.t()) :: State.t()
  def mark_rework_attempt_alerted(%State{} = state, issue_id, head_sha)
      when is_binary(issue_id) and is_binary(head_sha) do
    %{state | rework_attempt_alerted: MapSet.put(state.rework_attempt_alerted, {issue_id, head_sha})}
  end
end
