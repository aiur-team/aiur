defmodule Aiur.Orchestrator.PushRouting.ClearedDependency do
  @moduledoc """
  Resume for blockees whose declared dependency reached a terminal state or was
  removed, including the poll-time recheck. Public API stays on
  `Aiur.Orchestrator.PushRouting`.
  """

  import Aiur.Orchestrator.PushRouting.AutoResume, only: [blocker_identifier: 1, blocker_identifier_matches?: 2, clear_pending_auto_resume: 2, matching_blocker_pause_generation: 2]

  require Logger

  alias Aiur.{Alerts, Issue}
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, IssueSync, State, TrackerTasks}

  @doc false
  @spec maybe_resume_blockee_on_cleared_dependency(
          State.t(),
          map(),
          map(),
          :terminal | :removed,
          (Issue.t() -> {:ok, Issue.t()} | {:error, term()})
        ) :: State.t()
  def maybe_resume_blockee_on_cleared_dependency(
        state,
        blockee,
        blocker,
        clearance \\ :terminal,
        blocked_by_hydrator \\ &Dispatcher.default_blocked_by_hydrator/1
      )

  def maybe_resume_blockee_on_cleared_dependency(
        %State{} = state,
        blockee,
        blocker,
        clearance,
        blocked_by_hydrator
      )
      when is_map(blockee) and is_map(blocker) and clearance in [:terminal, :removed] and
             is_function(blocked_by_hydrator, 1) do
    expected = Map.get(state.running, blockee.id)

    TrackerTasks.run(
      state,
      {:dependency_hydration, blockee.id},
      fn ->
        hydrate_dependency_blockee({blocked_by_hydrator, blockee})
      end,
      fn arg1, arg2 ->
        apply_dependency_blockee(
          arg1,
          arg2,
          {blockee, blocker, clearance, expected}
        )
      end
    )
  end

  def maybe_resume_blockee_on_cleared_dependency(%State{} = state, _blockee, _blocker, _clearance, _hydrator),
    do: state

  @doc false
  @spec recheck_cleared_dependency_pauses(
          State.t(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()}),
          [term()],
          (Issue.t() -> {:ok, Issue.t()} | {:error, term()})
        ) :: State.t()
  def recheck_cleared_dependency_pauses(
        state,
        fetch_issue_states_fun,
        polled_issues \\ [],
        blocked_by_hydrator \\ &Dispatcher.default_blocked_by_hydrator/1
      )

  def recheck_cleared_dependency_pauses(
        %State{} = state,
        fetch_issue_states_fun,
        polled_issues,
        blocked_by_hydrator
      )
      when is_function(fetch_issue_states_fun, 1) and is_list(polled_issues) and
             is_function(blocked_by_hydrator, 1) do
    case paused_blocker_identifiers(state) do
      [] ->
        state

      blocker_identifiers ->
        expected = state.running

        TrackerTasks.run(
          state,
          :dependency_recheck,
          fn ->
            fetch_cleared_dependencies({blocked_by_hydrator, blocker_identifiers, fetch_issue_states_fun, polled_issues, state})
          end,
          fn arg1, arg2 -> apply_cleared_dependencies(arg1, arg2, {expected}) end
        )
    end
  end

  def recheck_cleared_dependency_pauses(%State{} = state, _fetch_issue_states_fun, _polled_issues, _hydrator),
    do: state

  defp cleared_dependency_resume_pending?(%{pending_auto_resume: %{resume_kind: :cleared_dependency}}), do: true

  defp cleared_dependency_resume_pending?(_entry), do: false

  defp paused_blocker_identifiers(%State{} = state) do
    state.running
    |> Map.values()
    |> Enum.flat_map(fn entry ->
      case {get_in(entry, [:blocker_pause, :blocker_identifier]), Map.get(entry, :paused_reason)} do
        {identifier, :blocker_dependency} when is_binary(identifier) -> [identifier]
        _ -> []
      end
    end)
    |> Enum.map(&blocker_fetch_identifier/1)
    |> Enum.uniq()
  end

  # Full identifiers of the running entries that are actually parked on a
  # blocker dependency. Everything else is never a candidate for a dependency
  # coordination event or an auto-resume.
  defp paused_blockee_identifiers(%State{} = state) do
    state.running
    |> Map.values()
    |> Enum.flat_map(fn entry ->
      case {Map.get(entry, :identifier), get_in(entry, [:blocker_pause, :blocker_identifier]), Map.get(entry, :paused_reason)} do
        {identifier, blocker_identifier, :blocker_dependency}
        when is_binary(identifier) and is_binary(blocker_identifier) ->
          [identifier]

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp fresh_blockee_issues(%State{} = state, polled_issues, fetch_issue_states_fun) do
    identifiers = paused_blockee_identifiers(state)
    polled = index_issues_by_identifiers(polled_issues, identifiers)

    identifiers
    |> Enum.reject(&Map.has_key?(polled, &1))
    |> refetch_blockee_issues(fetch_issue_states_fun)
    |> Map.merge(polled)
  end

  defp refetch_blockee_issues([], _fetch_issue_states_fun), do: %{}

  defp refetch_blockee_issues(identifiers, fetch_issue_states_fun) do
    case fetch_issue_states_fun.(Enum.map(identifiers, &blocker_fetch_identifier/1)) do
      {:ok, issues} when is_list(issues) -> index_issues_by_identifiers(issues, identifiers)
      _ -> %{}
    end
  end

  defp index_issues_by_identifiers(issues, identifiers) do
    Enum.reduce(identifiers, %{}, fn identifier, acc ->
      case Enum.find(issues, &matching_blockee_issue?(&1, identifier)) do
        nil -> acc
        issue -> Map.put(acc, identifier, issue)
      end
    end)
  end

  defp matching_blockee_issue?(%Issue{} = issue, identifier) do
    Issue.identifier_matches?(issue.id, issue.identifier, identifier) or
      Issue.identifier_matches?(issue.id, issue.identifier, blocker_fetch_identifier(identifier))
  end

  defp matching_blockee_issue?(_issue, _identifier), do: false

  defp resume_blockees_for_terminal_blocker(%{state: blocker_state} = blocker, state, blockee_issues, blocked_by_hydrator)
       when is_binary(blocker_state) do
    if blocker_terminal?(blocker),
      do: resume_blockees_for_cleared_blocker(state, blocker, blockee_issues, blocked_by_hydrator),
      else: state
  end

  defp resume_blockees_for_terminal_blocker(_blocker, state, _blockee_issues, _hydrator), do: state

  defp resume_blockees_for_cleared_blocker(state, blocker, blockee_issues, blocked_by_hydrator) do
    blocker = blocker_as_map(blocker)

    blockee_issues
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(state, fn {_identifier, blockee}, acc ->
      resume_blockee_for_cleared_blocker(acc, blockee, blocker, blocked_by_hydrator)
    end)
  end

  defp resume_blockee_for_cleared_blocker(state, blockee, blocker, blocked_by_hydrator) do
    # Both the coordination event and the resume consume the same decision, so
    # an agent can never be told about a blocker it was not parked on.
    case hydrate_blockee_blocked_by(blockee, blocked_by_hydrator) do
      {:ok, %Issue{} = hydrated_blockee} ->
        case cleared_dependency_match(state, hydrated_blockee, blocker) do
          {:ok, match} ->
            state
            |> IssueSync.enqueue_dependency_event(hydrated_blockee, blocker, :blocker_became_terminal)
            |> resume_cleared_dependency_blockee(match, hydrated_blockee, blocker, :terminal)

          :error ->
            state
        end

      :unavailable ->
        state
    end
  end

  # Hydrates `blocked_by` on a blockee being considered for auto-resume on a
  # cleared blocker. GitHub's poll never populates `blocked_by`, so without this
  # `other_open_blockers?/2` would always see an empty blocker set and
  # auto-resume a dependency-paused agent while a second blocker is still open
  # (#1631). Bounded: only called for blockees with a cleared blocker, so the
  # cost is proportional to dependency-clearance events, not tracker size.
  #
  # Fail-closed: an unreadable blocker set means the remaining blockers are
  # *unknown*, and resuming on unknown blockers reintroduces exactly the defect
  # this guard exists to prevent, so the agent stays parked until a later
  # successful read. A `/dependencies` outage therefore stalls one auto-resume
  # rather than waking work GitHub knows is still blocked.
  defp hydrate_blockee_blocked_by(blockee, blocked_by_hydrator) do
    case blocked_by_hydrator.(blockee) do
      {:ok, %Issue{} = hydrated} ->
        {:ok, hydrated}

      {:error, reason} ->
        Logger.warning(
          "Keeping dependency-paused blockee parked; blocked-by hydration failed for " <>
            "#{inspect(Map.get(blockee, :identifier))}: #{inspect(reason)} (fail-closed)"
        )

        :unavailable

      _other ->
        :unavailable
    end
  end

  defp blocker_as_map(blocker) when is_struct(blocker), do: Map.from_struct(blocker)

  defp blocker_as_map(blocker), do: blocker

  # The single place that decides "this running entry is parked on THIS blocker
  # and nothing else still blocks it".
  defp cleared_dependency_match(%State{} = state, blockee, blocker)
       when is_map(blockee) and is_map(blocker) do
    with blockee_identifier when is_binary(blockee_identifier) <- Map.get(blockee, :identifier),
         blocker_identifier when is_binary(blocker_identifier) <- blocker_identifier(blocker),
         entry when is_map(entry) <- State.find_running_by_identifier(state.running, blockee_identifier),
         {:ok, _generation} <- matching_blocker_pause_generation(entry, blocker_identifier),
         false <- cleared_dependency_resume_pending?(entry),
         false <- other_open_blockers?(blockee, blocker_identifier) do
      {:ok, %{entry: entry, blockee_identifier: blockee_identifier, blocker_identifier: blocker_identifier}}
    else
      _ -> :error
    end
  end

  defp cleared_dependency_match(%State{}, _blockee, _blocker), do: :error

  defp other_open_blockers?(blockee, cleared_blocker_identifier) do
    blockee
    |> Map.get(:blocked_by, [])
    |> Enum.reject(&blocker_identifier_matches?(blocker_identifier(&1), cleared_blocker_identifier))
    |> Enum.any?(&(not blocker_terminal?(&1)))
  end

  defp blocker_fetch_identifier(identifier) when is_binary(identifier) do
    identifier
    |> String.split("#")
    |> List.last()
  end

  defp blocker_terminal?(%{state: state_name}) when is_binary(state_name) do
    DispatchPolicy.terminal_issue_state?(state_name, DispatchPolicy.terminal_state_set())
  end

  defp blocker_terminal?(_blocker), do: false

  defp resume_cleared_dependency_blockee(state, match, blockee, blocker, clearance) do
    %{entry: entry, blockee_identifier: blockee_identifier, blocker_identifier: blocker_identifier} = match

    case Orchestrator.resume_paused_issue(state, entry, false) do
      {{:ok, :resumed}, next_state} ->
        Logger.info("Auto-resume on cleared blocker dependency: blockee=#{blockee_identifier} blocker=#{blocker_identifier}")

        emit_cleared_dependency_alert(blockee, entry, blocker, clearance)
        settle_cleared_dependency_resume(next_state, blockee_identifier, blocker_identifier)

      {{:error, reason}, next_state} ->
        Logger.warning("Auto-resume after cleared blocker dependency deferred: blockee=#{blockee_identifier} blocker=#{blocker_identifier} reason=#{inspect(reason)}")

        emit_deferred_cleared_dependency_alert(blockee, entry, blocker, reason)
        stamp_cleared_dependency_resume(next_state, blockee_identifier, blocker_identifier)
    end
  end

  defp settle_cleared_dependency_resume(state, blockee_identifier, blocker_identifier) do
    case State.find_running_by_identifier(state.running, blockee_identifier) do
      resumed_entry when is_map(resumed_entry) ->
        settle_resumed_entry(state, resumed_entry, blockee_identifier, blocker_identifier)

      _ ->
        stamp_cleared_dependency_resume(state, blockee_identifier, blocker_identifier)
    end
  end

  defp settle_resumed_entry(state, resumed_entry, blockee_identifier, blocker_identifier) do
    if State.paused_running_entry?(resumed_entry) do
      stamp_cleared_dependency_resume(state, blockee_identifier, blocker_identifier)
    else
      clear_pending_auto_resume(state, resumed_entry)
    end
  end

  defp stamp_cleared_dependency_resume(state, identifier, blocker_identifier) do
    case State.find_running_by_identifier(state.running, identifier) do
      running_entry when is_map(running_entry) ->
        issue_id = get_in(running_entry, [:issue, Access.key(:id)])
        generation = get_in(running_entry, [:blocker_pause, :generation])

        hint = %{
          resume_kind: :cleared_dependency,
          blocker_identifier: blocker_identifier,
          pause_generation: generation,
          topic: "tracker.dependency_cleared",
          stamped_at: DateTime.utc_now()
        }

        %{state | running: Map.put(state.running, issue_id, Map.put(running_entry, :pending_auto_resume, hint))}

      _ ->
        state
    end
  end

  # Emitted only once the resume actually succeeded. This is deliberately NOT
  # the `agent.attention.paused-blocker_dependency` topic: raising that pause
  # attention here told the operator the agent was parked on a blocker at the
  # moment the blocker had in fact cleared, and it stayed raised with no
  # `.resolved` whenever the resume was capacity-deferred. The real pause
  # attention is owned by `OperatorMessages`, which raises it on the pause and
  # resolves it on the observed paused -> working transition.
  defp emit_cleared_dependency_alert(blockee, entry, blocker, clearance) do
    blocker_identifier = blocker_identifier(blocker)

    Alerts.emit_system("ticket.#{Map.get(blockee, :identifier)}.agent.dependency_cleared",
      issue: Map.get(blockee, :identifier),
      workspace: Map.get(entry, :workspace_path),
      worker_host: Map.get(entry, :worker_host),
      reason: cleared_dependency_reason(blocker_identifier, Map.get(blocker, :state), clearance),
      needs_attention: false,
      severity: "info",
      central: true
    )
  end

  defp emit_deferred_cleared_dependency_alert(blockee, entry, blocker, reason) do
    blocker_identifier = blocker_identifier(blocker)

    Alerts.emit_system("ticket.#{Map.get(blockee, :identifier)}.agent.auto_resume_deferred",
      issue: Map.get(blockee, :identifier),
      workspace: Map.get(entry, :workspace_path),
      worker_host: Map.get(entry, :worker_host),
      reason: "Blocker #{blocker_identifier} is clear; the automatic resume is waiting for a dispatch slot (#{inspect(reason)}).",
      needs_attention: false,
      severity: "info",
      central: true
    )
  end

  defp cleared_dependency_reason(blocker_identifier, blocker_state, :terminal),
    do: "Blocker #{blocker_identifier} reached terminal state #{blocker_state}; automatic resume requested."

  defp cleared_dependency_reason(blocker_identifier, _blocker_state, :removed),
    do: "Dependency on blocker #{blocker_identifier} was removed; automatic resume requested."

  defp hydrate_dependency_blockee({blocked_by_hydrator, blockee}) do
    hydrate_blockee_blocked_by(blockee, blocked_by_hydrator)
  end

  defp apply_dependency_blockee(current, {:ok, %Issue{} = hydrated}, {blockee, blocker, clearance, expected}) do
    if Map.get(current.running, blockee.id) == expected do
      resume_matching_dependency(current, hydrated, blocker, clearance)
    else
      current
    end
  end

  defp apply_dependency_blockee(current, _result, _context), do: current

  defp resume_matching_dependency(current, hydrated, blocker, clearance) do
    case cleared_dependency_match(current, hydrated, blocker) do
      {:ok, match} -> resume_cleared_dependency_blockee(current, match, hydrated, blocker, clearance)
      :error -> current
    end
  end

  defp fetch_cleared_dependencies({blocked_by_hydrator, blocker_identifiers, fetch_issue_states_fun, polled_issues, state}) do
    with {:ok, blockers} when is_list(blockers) <- fetch_issue_states_fun.(blocker_identifiers) do
      blockees = fresh_blockee_issues(state, polled_issues, fetch_issue_states_fun)

      hydrated =
        Map.new(blockees, fn arg1 ->
          hydrate_dependency_entry(arg1, {blocked_by_hydrator})
        end)

      {:ok, blockers, hydrated}
    end
  end

  defp apply_cleared_dependencies(
         current,
         {:ok, blockers, hydrated},
         {expected}
       ) do
    blockees =
      Enum.reduce(hydrated, %{}, fn arg1, arg2 ->
        retain_current_dependency_entry(
          arg1,
          arg2,
          {current, expected}
        )
      end)

    Enum.reduce(
      blockers,
      current,
      &resume_blockees_for_terminal_blocker(&1, &2, blockees, fn issue -> {:ok, issue} end)
    )
  end

  defp apply_cleared_dependencies(current, _, {_expected}) do
    current
  end

  defp hydrate_dependency_entry(
         {id, issue},
         {blocked_by_hydrator}
       ) do
    {id, hydrate_blockee_blocked_by(issue, blocked_by_hydrator)}
  end

  defp retain_current_dependency_entry(
         {id, {:ok, %Issue{} = issue}},
         acc,
         {current, expected}
       ) do
    key = State.find_running_key_by_identifier(current.running, id)

    if Map.get(current.running, key) == Map.get(expected, key) do
      Map.put(acc, id, issue)
    else
      acc
    end
  end

  defp retain_current_dependency_entry(
         _,
         acc,
         {_current, _expected}
       ) do
    acc
  end
end
