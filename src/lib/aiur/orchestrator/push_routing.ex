defmodule Aiur.Orchestrator.PushRouting do
  @moduledoc """
  Agent pause-on-request, default-branch push notification, sleeping state, and
  generation-matched auto-resume for explicit blocker clearances and transient
  GitHub budget recovery. Both paths retain shared `pending_auto_resume` hints
  until the corresponding pause is confirmed or capacity becomes available.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{Alerts, Config, Issue}
  alias Aiur.Events.BranchRefStore
  alias Aiur.Events.GithubKeys
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, GithubBudgetPause, IssueSync, PauseResume, State}

  @spec mark_sleeping(String.t()) :: :ok
  def mark_sleeping(issue_identifier), do: mark_sleeping(Aiur.Orchestrator, issue_identifier)

  @spec mark_sleeping(GenServer.server(), String.t()) :: :ok
  def mark_sleeping(server, issue_identifier) when is_binary(issue_identifier) do
    GenServer.cast(server, {:mark_sleeping, issue_identifier})
  end

  @spec apply_agent_unblocked(State.t(), String.t()) :: State.t()
  def apply_agent_unblocked(%State{} = state, blocker_identifier)
      when is_binary(blocker_identifier) do
    topic = "ticket." <> blocker_identifier <> ".agent.unblocked"
    metadata = BranchRefStore.latest(blocker_identifier)

    if metadata,
      do: maybe_resume_blockees_on_unblocked(state, blocker_identifier, topic, metadata),
      else: state
  end

  @spec maybe_pause_on_request(State.t(), String.t() | integer()) :: State.t()
  def maybe_pause_on_request(%State{} = state, identifier), do: maybe_pause_on_request(state, identifier, %{})

  @spec maybe_pause_on_request(State.t(), String.t() | integer(), map()) :: State.t()
  def maybe_pause_on_request(%State{} = state, identifier, event) do
    case State.find_running_by_identifier(state.running, identifier) do
      running_entry when is_map(running_entry) ->
        existing_status =
          (Map.get(running_entry, :control) || %{}) |> Map.get(:status, :working)

        cond do
          existing_status == :paused ->
            state

          State.deactivated_running_entry?(running_entry) ->
            state

          true ->
            {running_entry, pause_reason} = prepare_agent_pause(running_entry, event)

            {_reply, state} =
              PauseResume.request_pause(
                state,
                running_entry,
                Map.get(running_entry, :issue),
                pause_reason
              )

            state
        end

      _ ->
        state
    end
  end

  @doc false
  @spec recover_github_budget_pauses(State.t(), integer()) :: State.t()
  def recover_github_budget_pauses(%State{} = state, now_ms \\ System.system_time(:millisecond)),
    do: GithubBudgetPause.recover_observed(state, now_ms)

  @doc false
  @spec recover_github_budget_pause(State.t(), String.t(), pos_integer(), integer()) :: State.t()
  def recover_github_budget_pause(%State{} = state, identifier, generation, now_ms \\ System.system_time(:millisecond)),
    do: GithubBudgetPause.recover_expired(state, identifier, generation, now_ms)

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
    # The caller on this path already holds the freshly polled blockee, so the
    # blocker set read by `cleared_dependency_match/3` is current — once the
    # blockee's `blocked_by` has been hydrated. GitHub polls never populate it,
    # and `other_open_blockers?/2` below decides whether a second blocker keeps
    # the agent parked, so without hydration every GitHub blockee looks
    # unblocked and gets auto-resumed while a second blocker is still open
    # (#1631).
    case hydrate_blockee_blocked_by(blockee, blocked_by_hydrator) do
      {:ok, %Issue{} = hydrated_blockee} ->
        case cleared_dependency_match(state, hydrated_blockee, blocker) do
          {:ok, match} ->
            resume_cleared_dependency_blockee(state, match, hydrated_blockee, blocker, clearance)

          :error ->
            state
        end

      :unavailable ->
        state
    end
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
    with [_ | _] = blocker_identifiers <- paused_blocker_identifiers(state),
         {:ok, blockers} when is_list(blockers) <- fetch_issue_states_fun.(blocker_identifiers) do
      # This path exists for blockers absent from the active poll, so the
      # blockee snapshot stored in the running entry is exactly the one most
      # likely to be stale. Resolve the freshest blockee issue up front and
      # fail closed when none is obtainable, rather than waking an agent on a
      # stale `blocked_by`.
      blockee_issues = fresh_blockee_issues(state, polled_issues, fetch_issue_states_fun)

      Enum.reduce(blockers, state, &resume_blockees_for_terminal_blocker(&1, &2, blockee_issues, blocked_by_hydrator))
    else
      _ -> state
    end
  end

  def recheck_cleared_dependency_pauses(%State{} = state, _fetch_issue_states_fun, _polled_issues, _hydrator),
    do: state

  @doc false
  @spec record_blocker_branch_push(State.t(), String.t() | integer(), map()) :: State.t()
  def record_blocker_branch_push(%State{} = state, blocker_identifier, event) do
    case validated_branch_metadata(blocker_identifier, event) do
      {:ok, metadata} ->
        case BranchRefStore.record_and_ready_unblock(metadata.ref, metadata.sha) do
          {:ok, %{} = pending_unblock} ->
            topic = "ticket.#{blocker_identifier}.agent.unblocked"
            unblock_key = topic <> ":" <> pending_unblock.sha
            resume_and_maybe_ack_unblock(state, blocker_identifier, topic, pending_unblock, unblock_key)

          {:ok, nil} ->
            state

          :error ->
            state
        end

      :error ->
        state
    end
  end

  @doc false
  @spec validated_unblock_metadata(String.t() | integer(), map()) ::
          %{ref: String.t(), sha: String.t()} | nil
  def validated_unblock_metadata(blocker_identifier, event) do
    case validated_branch_metadata(blocker_identifier, event) do
      {:ok, metadata} -> metadata
      :error -> nil
    end
  end

  @spec maybe_notify_agents_on_default_branch_push(State.t(), String.t(), map()) :: State.t()
  def maybe_notify_agents_on_default_branch_push(%State{} = state, branch, event)
      when is_binary(branch) do
    if branch == Config.base_branch() do
      sha = Map.get(event, :sha) || Map.get(event, "sha")

      Logger.info(
        "Default branch advanced; not terminating agents — each handles the push via its system.#{branch}.branch.push subscription (active turns continue uninterrupted, standby wakes): sha=#{sha || "-"}"
      )
    end

    state
  end

  def maybe_notify_agents_on_default_branch_push(%State{} = state, _branch, _event),
    do: state

  @spec maybe_mark_sleeping(State.t(), String.t() | integer()) :: State.t()
  def maybe_mark_sleeping(%State{} = state, identifier) do
    case State.find_running_by_identifier(state.running, identifier) do
      running_entry when is_map(running_entry) ->
        existing_status =
          (Map.get(running_entry, :control) || %{}) |> Map.get(:status, :working)

        if existing_status == :working do
          Orchestrator.transition_control_status(state, running_entry, :sleeping, "stream.idle_close")
        else
          state
        end

      _ ->
        state
    end
  end

  @spec maybe_resume_blockees_on_unblocked(State.t(), String.t() | integer(), String.t(), map()) :: State.t()
  def maybe_resume_blockees_on_unblocked(%State{} = state, blocker_identifier, topic, metadata) do
    unblock_key = topic <> ":" <> metadata.sha

    case BranchRefStore.register_unblock(metadata.ref, metadata.sha) do
      :ready -> resume_and_maybe_ack_unblock(state, blocker_identifier, topic, metadata, unblock_key)
      :pending -> state
      :error -> state
    end
  end

  @doc false
  @spec maybe_resume_blockees_on_merged_ticket(State.t(), String.t() | integer()) :: State.t()
  def maybe_resume_blockees_on_merged_ticket(%State{} = state, blocker_identifier) do
    blocker_identifier = to_string(blocker_identifier)
    topic = "ticket.#{blocker_identifier}.pr.merged"

    state.running
    |> Map.values()
    |> Enum.reduce(state, &resume_or_record_merged_blockee(&2, &1, blocker_identifier, topic))
  end

  @doc false
  @spec merged_ticket_blockee_count(State.t(), String.t() | integer()) :: non_neg_integer()
  def merged_ticket_blockee_count(%State{} = state, blocker_identifier) do
    blocker_identifier = to_string(blocker_identifier)

    Enum.count(state.running, fn {_issue_id, entry} ->
      Map.get(entry, :paused_reason) == :blocker_dependency and
        get_in(entry, [:blocker_pause, :blocker_identifier]) == blocker_identifier
    end)
  end

  defp resume_and_maybe_ack_unblock(state, blocker_identifier, topic, metadata, unblock_key) do
    recipient_identifiers = relevant_recipient_identifiers(state, blocker_identifier, topic)
    next = resume_matching_running_entries(state, blocker_identifier, topic, unblock_key)

    if recipients_consumed?(next, recipient_identifiers, unblock_key) do
      if BranchRefStore.acknowledge_unblock(metadata.ref, metadata.sha) == :error do
        Logger.warning("Final unblock acknowledgement remains pending after persistence failure: blocker=#{blocker_identifier} ref=#{metadata.ref} sha=#{metadata.sha}")
      end
    end

    next
  end

  defp relevant_recipient_identifiers(state, blocker_identifier, topic) do
    state
    |> running_recipient_identifiers(blocker_identifier, topic)
    |> MapSet.union(declared_recipient_identifiers(state, blocker_identifier))
    |> MapSet.to_list()
  end

  defp running_recipient_identifiers(state, blocker_identifier, topic) do
    Enum.reduce(state.running, MapSet.new(), fn {_issue_id, entry}, recipients ->
      if relevant_running_recipient?(entry, blocker_identifier, topic),
        do: MapSet.put(recipients, Map.get(entry, :identifier)),
        else: recipients
    end)
  end

  defp relevant_running_recipient?(entry, blocker_identifier, topic) when is_map(entry) do
    identifier = Map.get(entry, :identifier)

    is_binary(identifier) and identifier != to_string(blocker_identifier) and
      not State.deactivated_running_entry?(entry) and
      (subscribed_to_topic?(identifier, topic) or
         match?({:ok, _generation}, matching_blocker_pause_generation(entry, blocker_identifier)))
  end

  defp relevant_running_recipient?(_entry, _blocker_identifier, _topic), do: false

  defp declared_recipient_identifiers(state, blocker_identifier) do
    Enum.reduce(state.last_polled_issues, MapSet.new(), fn {_issue_id, issue}, recipients ->
      identifier = Map.get(issue, :identifier)

      if is_binary(identifier) and declares_blocker?(issue, blocker_identifier),
        do: MapSet.put(recipients, Map.get(issue, :identifier)),
        else: recipients
    end)
  end

  defp declares_blocker?(issue, blocker_identifier) do
    issue
    |> IssueSync.blocker_map()
    |> Map.values()
    |> Enum.any?(&(blocker_identifier(&1) == to_string(blocker_identifier)))
  end

  defp blocker_identifier(blocker),
    do: Map.get(blocker, :identifier) || Map.get(blocker, "identifier")

  defp recipients_consumed?(_state, [], _unblock_key), do: false

  defp recipients_consumed?(state, recipient_identifiers, unblock_key) do
    Enum.all?(recipient_identifiers, fn identifier ->
      state.running
      |> State.find_running_by_identifier(identifier)
      |> consumed_unblock?(unblock_key)
    end)
  end

  defp resume_matching_running_entries(state, blocker_identifier, topic, unblock_key) do
    Enum.reduce(state.running, state, fn running, acc ->
      resume_matching_running_entry(running, acc, blocker_identifier, topic, unblock_key)
    end)
  end

  defp resume_matching_running_entry({_issue_id, entry}, state, blocker_identifier, topic, unblock_key)
       when is_map(entry) do
    if State.deactivated_running_entry?(entry),
      do: state,
      else: maybe_record_or_resume_for_topic(state, entry, blocker_identifier, topic, unblock_key)
  end

  defp resume_matching_running_entry(_running, state, _blocker_identifier, _topic, _unblock_key),
    do: state

  @doc false
  @spec reconcile_pending_auto_resumes(State.t()) :: State.t()
  def reconcile_pending_auto_resumes(%State{} = state) do
    reconciled = reconcile_durable_unblocks(state)
    Enum.reduce(reconciled.running, reconciled, &reconcile_pending_auto_resume/2)
  end

  defp reconcile_pending_auto_resume({_issue_id, entry}, state) do
    case Map.get(entry, :pending_auto_resume) do
      %{} = hint when is_map(hint) -> maybe_drain_pending_auto_resume(state, entry, hint)
      _ -> state
    end
  end

  defp reconcile_durable_unblocks(state) do
    state.running
    |> Enum.reduce(MapSet.new(), fn {_issue_id, entry}, blockers ->
      case Map.get(entry, :blocker_pause) do
        %{blocker_identifier: identifier} -> MapSet.put(blockers, identifier)
        _ -> blockers
      end
    end)
    |> Enum.reduce(state, fn blocker_identifier, acc ->
      case BranchRefStore.ready_unblock(blocker_identifier) do
        %{} = metadata ->
          topic = "ticket.#{blocker_identifier}.agent.unblocked"
          unblock_key = topic <> ":" <> metadata.sha
          resume_and_maybe_ack_unblock(acc, blocker_identifier, topic, metadata, unblock_key)

        nil ->
          acc
      end
    end)
  end

  defp maybe_record_or_resume_for_topic(state, entry, blocker_identifier, topic, unblock_key) do
    identifier = Map.get(entry, :identifier)

    cond do
      not is_binary(identifier) ->
        state

      identifier == blocker_identifier ->
        state

      consumed_unblock?(entry, unblock_key) ->
        state

      subscribed_to_topic?(identifier, topic) ->
        route_matching_blocker_pause(state, entry, identifier, blocker_identifier, topic, unblock_key)

      true ->
        state
    end
  end

  defp route_matching_blocker_pause(state, entry, identifier, blocker_identifier, topic, unblock_key) do
    case matching_blocker_pause_generation(entry, blocker_identifier) do
      {:ok, pause_generation} ->
        if State.paused_running_entry?(entry) do
          attempt_auto_resume(state, entry, identifier, blocker_identifier, topic, unblock_key, pause_generation)
        else
          stamp_pending_auto_resume(state, identifier, blocker_identifier, topic, unblock_key, pause_generation)
        end

      :error ->
        state
    end
  end

  defp resume_or_record_merged_blockee(state, entry, blocker_identifier, topic) do
    case matching_blocker_pause_generation(entry, blocker_identifier) do
      {:ok, pause_generation} ->
        resume_or_record_matching_blockee(
          state,
          entry,
          blocker_identifier,
          topic,
          pause_generation
        )

      :error ->
        state
    end
  end

  defp resume_or_record_matching_blockee(state, entry, blocker_identifier, topic, pause_generation) do
    identifier = Map.get(entry, :identifier)

    if State.paused_running_entry?(entry) do
      attempt_auto_resume(state, entry, identifier, blocker_identifier, topic, topic, pause_generation)
    else
      stamp_pending_auto_resume(state, identifier, blocker_identifier, topic, topic, pause_generation)
    end
  end

  # Resume can fail when the concurrent-agent cap is already full —
  # the blockee would otherwise sit silently paused forever because
  # the explicit unblock event is consumed exactly once. Log a warning so
  # Executors can see
  # the cap is blocking the resume, and stamp a hint on the entry so a
  # future reconcile tick (when a slot opens up) can drain the queue.
  defp attempt_auto_resume(state, _entry, identifier, blocker_identifier, topic, unblock_key, pause_generation) do
    Logger.info("Auto-resume on blocker unblocked: blockee=#{identifier} blocker=#{blocker_identifier} topic=#{topic}")

    state =
      stamp_pending_auto_resume(
        state,
        identifier,
        blocker_identifier,
        topic,
        unblock_key,
        pause_generation
      )

    entry = State.find_running_by_identifier(state.running, identifier)

    # operator?: false — an automated blocker resume must preserve a
    # duration-capped agent's cumulative overrun (no fresh budget).
    case Orchestrator.resume_paused_issue(state, entry, false) do
      {{:ok, :resumed}, next_state} ->
        next_state

      {{:error, :max_concurrent_agents_reached}, next_state} ->
        Logger.warning("Auto-resume deferred (cap full): blockee=#{identifier} blocker=#{blocker_identifier} topic=#{topic}; entry remains paused with pending_auto_resume hint")

        stamp_pending_auto_resume(next_state, identifier, blocker_identifier, topic, unblock_key, pause_generation)

      {{:error, reason}, next_state} ->
        Logger.warning("Auto-resume failed: blockee=#{identifier} blocker=#{blocker_identifier} reason=#{inspect(reason)}")

        next_state
    end
  end

  # Record a pending_auto_resume marker on the running entry so a
  # future tick (reconcile_pending_auto_resumes/1) can retry once a
  # slot opens up. Without this the cap-full case loses the unblock
  # signal and the blockee stays paused forever.
  defp stamp_pending_auto_resume(state, identifier, blocker_identifier, topic, unblock_key, pause_generation) do
    case State.find_running_by_identifier(state.running, identifier) do
      running_entry when is_map(running_entry) ->
        issue_id = get_in(running_entry, [:issue, Access.key(:id)])

        hint = %{
          blocker_identifier: blocker_identifier,
          topic: topic,
          unblock_key: unblock_key,
          pause_generation: pause_generation,
          stamped_at: DateTime.utc_now()
        }

        updated_entry = Map.put(running_entry, :pending_auto_resume, hint)
        %{state | running: Map.put(state.running, issue_id, updated_entry)}

      _ ->
        state
    end
  end

  # snapshot/1 is a synchronous GenServer.call to the per-identifier
  # store. The case clauses handle the documented contract; the rescue
  # only narrows to :exit (call timeout) so genuine bugs surface as
  # exceptions in tests instead of being silently swallowed.
  defp subscribed_to_topic?(identifier, topic) do
    case SubscriptionStore.snapshot(identifier) do
      %{subscribed_to: subs} when is_list(subs) ->
        Enum.any?(subs, fn
          %{"topic" => t} -> t == topic
          %{topic: t} -> t == topic
          _ -> false
        end)

      _ ->
        false
    end
  catch
    :exit, reason ->
      Logger.warning("subscribed_to_topic? store call failed: identifier=#{identifier} topic=#{topic} reason=#{inspect(reason)}")

      false
  end

  defp maybe_drain_pending_auto_resume(state, entry, hint) do
    case pending_auto_resume_action(entry, hint) do
      :clear -> clear_pending_auto_resume(state, entry)
      :wait -> state
      :drain -> drain_pending_auto_resume(state, entry, hint)
    end
  end

  defp pending_auto_resume_action(entry, hint) do
    cond do
      State.deactivated_running_entry?(entry) -> :clear
      State.paused_running_entry?(entry) -> if matching_hint_pause?(entry, hint), do: :drain, else: :clear
      matching_hint_context?(entry, hint) -> :wait
      true -> :clear
    end
  end

  defp drain_pending_auto_resume(state, entry, hint) do
    if GithubBudgetPause.matching_resume_pending?(state, entry) do
      state
    else
      identifier = Map.get(entry, :identifier)
      blocker_identifier = Map.get(hint, :blocker_identifier)
      topic = Map.get(hint, :topic)

      # operator?: false — same automated path as attempt_auto_resume,
      # just deferred until a slot opened; preserve the duration overrun.
      case Orchestrator.resume_paused_issue(state, entry, false) do
        {{:ok, :resumed}, next_state} ->
          Logger.info("Auto-resume drained: blockee=#{identifier} blocker=#{blocker_identifier} topic=#{topic}")
          maybe_clear_drained_cleared_dependency_resume(next_state, identifier, hint)

        {{:error, _reason}, next_state} ->
          # Cap still full or another error — keep the hint for the
          # next reconcile tick.
          next_state
      end
    end
  end

  defp maybe_clear_drained_cleared_dependency_resume(state, identifier, %{resume_kind: :cleared_dependency}) do
    case State.find_running_by_identifier(state.running, identifier) do
      running_entry when is_map(running_entry) ->
        if State.paused_running_entry?(running_entry), do: state, else: clear_pending_auto_resume(state, running_entry)

      _ ->
        state
    end
  end

  defp maybe_clear_drained_cleared_dependency_resume(state, _identifier, _hint), do: state

  defp clear_pending_auto_resume(state, entry) do
    issue_id = get_in(entry, [:issue, Access.key(:id)])

    case Map.get(state.running, issue_id) do
      running_entry when is_map(running_entry) ->
        updated = Map.delete(running_entry, :pending_auto_resume)
        %{state | running: Map.put(state.running, issue_id, updated)}

      _ ->
        state
    end
  end

  defp consumed_unblock?(entry, unblock_key) when is_map(entry) do
    entry
    |> Map.get(:consumed_unblocks, MapSet.new())
    |> MapSet.member?(unblock_key)
  end

  defp consumed_unblock?(_entry, _unblock_key), do: false

  defp mark_unblock_consumed(state, identifier, unblock_key) do
    case State.find_running_by_identifier(state.running, identifier) do
      running_entry when is_map(running_entry) ->
        issue_id = get_in(running_entry, [:issue, Access.key(:id)])
        consumed = Map.get(running_entry, :consumed_unblocks, MapSet.new())
        updated = Map.put(running_entry, :consumed_unblocks, MapSet.put(consumed, unblock_key))
        %{state | running: Map.put(state.running, issue_id, updated)}

      _ ->
        state
    end
  end

  defp finish_blocker_resume(state, identifier, unblock_key) do
    state
    |> mark_unblock_consumed(identifier, unblock_key)
    |> update_running_entry(identifier, fn entry ->
      entry |> Map.delete(:pending_auto_resume) |> Map.delete(:blocker_pause)
    end)
  end

  @doc false
  @spec finalize_applied_resume(State.t(), term()) :: State.t()
  def finalize_applied_resume(%State{} = state, issue_id) do
    case Map.get(state.running, issue_id) do
      %{pending_auto_resume: %{resume_kind: :cleared_dependency}} = running_entry ->
        clear_pending_auto_resume(state, running_entry)

      %{identifier: identifier, pending_auto_resume: %{unblock_key: unblock_key} = hint}
      when is_binary(identifier) and is_binary(unblock_key) ->
        state
        |> finish_blocker_resume(identifier, unblock_key)
        |> maybe_acknowledge_applied_unblock(hint)

      running_entry when is_map(running_entry) ->
        updated =
          running_entry
          |> Map.delete(:pending_auto_resume)
          |> Map.delete(:blocker_pause)
          |> Map.delete(:github_budget_pause)
          |> Map.delete(:github_budget_pause_timer)

        %{state | running: Map.put(state.running, issue_id, updated)}

      _ ->
        state
    end
  end

  defp maybe_acknowledge_applied_unblock(state, %{blocker_identifier: blocker_identifier}) do
    case BranchRefStore.ready_unblock(blocker_identifier) do
      %{ref: ref, sha: sha} ->
        topic = "ticket.#{blocker_identifier}.agent.unblocked"
        unblock_key = topic <> ":" <> sha
        recipients = relevant_recipient_identifiers(state, blocker_identifier, topic)
        acknowledge_if_consumed(state, recipients, unblock_key, blocker_identifier, ref, sha)
        state

      nil ->
        state
    end
  end

  defp acknowledge_if_consumed(state, recipients, unblock_key, blocker_identifier, ref, sha) do
    if recipients_consumed?(state, recipients, unblock_key) and
         BranchRefStore.acknowledge_unblock(ref, sha) == :error do
      Logger.warning("Final unblock acknowledgement remains pending after persistence failure: blocker=#{blocker_identifier} ref=#{ref} sha=#{sha}")
    end
  end

  defp prepare_agent_pause(entry, event) do
    payload = event_payload(event)
    blocker_identifier = Map.get(payload, :blocker_identifier) || Map.get(payload, "blocker_identifier")
    reason = Map.get(payload, :reason) || Map.get(payload, "reason")

    cond do
      reason == "dependency" and (is_binary(blocker_identifier) or is_integer(blocker_identifier)) ->
        generation = Map.get(entry, :blocker_pause_generation, 0) + 1

        prepared =
          entry
          |> Map.put(:blocker_pause_generation, generation)
          |> Map.put(:blocker_pause, %{blocker_identifier: to_string(blocker_identifier), generation: generation})
          |> clear_budget_pause_context()

        {prepared, :blocker_dependency}

      budget_pause = GithubBudgetPause.parse(payload, entry) ->
        GithubBudgetPause.cancel_timer(entry)
        GithubBudgetPause.emit_escalation_if_needed(entry, budget_pause.generation)

        timer_ref =
          GithubBudgetPause.schedule_expiry(
            Map.get(entry, :identifier),
            budget_pause.generation,
            budget_pause.reset_at_ms
          )

        prepared =
          entry
          |> Map.put(:github_budget_pause_generation, budget_pause.generation)
          |> Map.put(:github_budget_last_pause_ms, System.system_time(:millisecond))
          |> Map.put(:github_budget_pause, budget_pause)
          |> Map.put(:github_budget_pause_timer, timer_ref)
          |> Map.delete(:blocker_pause)
          |> Map.delete(:pending_auto_resume)

        {prepared, :github_budget_hold}

      true ->
        prepared =
          entry
          |> Map.delete(:blocker_pause)
          |> clear_budget_pause_context()

        {prepared, :agent_pause_request}
    end
  end

  defp clear_budget_pause_context(entry) do
    GithubBudgetPause.clear_context(entry)
  end

  defp matching_blocker_pause_generation(entry, blocker_identifier) do
    generation = get_in(entry, [:blocker_pause, :generation])

    if Map.get(entry, :paused_reason) == :blocker_dependency and
         blocker_identifier_matches?(get_in(entry, [:blocker_pause, :blocker_identifier]), blocker_identifier) and
         is_integer(generation) and generation > 0 and
         Map.get(entry, :blocker_pause_generation) == generation do
      {:ok, generation}
    else
      :error
    end
  end

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

  defp blocker_identifier_matches?(stored, current) when is_binary(stored) and is_binary(current) do
    Issue.identifier_matches?(nil, stored, current)
  end

  defp blocker_identifier_matches?(_stored, _current), do: false

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

  defp matching_hint_pause?(entry, %{resume_kind: :github_budget_recovered} = hint),
    do: GithubBudgetPause.matching_hint_pause?(entry, hint)

  defp matching_hint_pause?(entry, hint) do
    generation = get_in(entry, [:blocker_pause, :generation])

    get_in(entry, [:blocker_pause, :blocker_identifier]) == Map.get(hint, :blocker_identifier) and
      is_integer(generation) and generation > 0 and
      generation == Map.get(hint, :pause_generation) and
      Map.get(entry, :blocker_pause_generation) == generation and
      Map.get(entry, :paused_reason) == :blocker_dependency
  end

  defp matching_hint_context?(entry, %{resume_kind: :github_budget_recovered} = hint),
    do: GithubBudgetPause.matching_hint_context?(entry, hint)

  defp matching_hint_context?(entry, hint) do
    generation = get_in(entry, [:blocker_pause, :generation])

    generation == Map.get(hint, :pause_generation) and
      Map.get(entry, :blocker_pause_generation) == generation and
      (Map.get(entry, :paused_reason) == :blocker_dependency or
         match?(%{reason: :blocker_dependency}, Map.get(entry, :pending_pause_reason)))
  end

  defp validated_branch_metadata(blocker_identifier, event) do
    payload = event_payload(event)
    ref = Map.get(payload, :ref) || Map.get(payload, "ref")
    sha = Map.get(payload, :sha) || Map.get(payload, "sha")

    with true <- is_binary(ref) and ref != "",
         true <- is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/i, sha),
         {:ticket, identifier, _topic} <- GithubKeys.ref_to_topic(ref),
         true <- to_string(identifier) == to_string(blocker_identifier) do
      {:ok, %{ref: ref, sha: String.downcase(sha)}}
    else
      _ -> :error
    end
  end

  defp event_payload(event), do: Map.get(event, :payload) || Map.get(event, "payload") || event

  defp update_running_entry(state, identifier, fun) do
    case State.find_running_by_identifier(state.running, identifier) do
      running_entry when is_map(running_entry) ->
        issue_id = get_in(running_entry, [:issue, Access.key(:id)])
        %{state | running: Map.put(state.running, issue_id, fun.(running_entry))}

      _ ->
        state
    end
  end
end
