defmodule Aiur.Orchestrator.PushRouting.AutoResume do
  @moduledoc """
  Generation-matched auto-resume for explicit blocker clearances: recipient
  matching, the retained `pending_auto_resume` hint, and unblock acknowledgement.
  Public API stays on `Aiur.Orchestrator.PushRouting`.
  """

  require Logger

  alias Aiur.Issue
  alias Aiur.Events.BranchRefStore
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{GithubBudgetPause, IssueSync, State}

  @doc false
  @spec resume_and_maybe_ack_unblock(State.t(), String.t(), String.t(), map(), term()) :: State.t()
  def resume_and_maybe_ack_unblock(state, blocker_identifier, topic, metadata, unblock_key) do
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

  @doc false
  @spec blocker_identifier(map()) :: term()
  def blocker_identifier(blocker),
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

  @doc false
  @spec resume_or_record_merged_blockee(State.t(), map(), String.t(), String.t()) :: State.t()
  def resume_or_record_merged_blockee(state, entry, blocker_identifier, topic) do
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

  defp subscribed_to_topic?(identifier, topic) do
    identifier
    |> SubscriptionStore.subscriptions()
    |> Enum.any?(fn
      %{"topic" => t} -> t == topic
      %{topic: t} -> t == topic
      _ -> false
    end)
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

  @doc false
  @spec clear_pending_auto_resume(State.t(), map()) :: State.t()
  def clear_pending_auto_resume(state, entry) do
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

  @doc false
  @spec matching_blocker_pause_generation(map(), term()) :: {:ok, pos_integer()} | :error
  def matching_blocker_pause_generation(entry, blocker_identifier) do
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

  @doc false
  @spec blocker_identifier_matches?(term(), term()) :: boolean()
  def blocker_identifier_matches?(stored, current) when is_binary(stored) and is_binary(current) do
    Issue.identifier_matches?(nil, stored, current)
  end

  def blocker_identifier_matches?(_stored, _current), do: false

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
