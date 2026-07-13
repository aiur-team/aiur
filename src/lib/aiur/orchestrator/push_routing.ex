defmodule Aiur.Orchestrator.PushRouting do
  @moduledoc """
  Agent pause-on-request, default-branch push notification, sleeping state, and
  explicit blocker-unblocked auto-resume with pending_auto_resume drain.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.Config
  alias Aiur.Events.GithubKeys
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.State

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

    metadata =
      state.running
      |> Map.values()
      |> Enum.find_value(&get_in(&1, [:blocker_branch_pushes, blocker_identifier]))

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
            # Queue the pause control message; ignore the reply because
            # we're about to transition the entry's status optimistically
            # in transition_control_status. The worker confirmation
            # arrives later via :worker_control_state :paused and the
            # already-equal status short-circuit drops the duplicate
            # transition cleanly.
            _ = Orchestrator.send_pause_control_message(state, identifier)
            running_entry = prepare_agent_pause(running_entry, event)
            Orchestrator.transition_control_status(state, running_entry, :paused, "agent.pause.request")
        end

      _ ->
        state
    end
  end

  @doc false
  @spec record_blocker_branch_push(State.t(), String.t() | integer(), map()) :: State.t()
  def record_blocker_branch_push(%State{} = state, blocker_identifier, event) do
    case validated_branch_metadata(blocker_identifier, event) do
      {:ok, metadata} ->
        topic = "ticket.#{blocker_identifier}.agent.unblocked"

        running =
          Map.new(state.running, fn {issue_id, entry} ->
            {issue_id, maybe_record_blocker_push(entry, blocker_identifier, topic, metadata)}
          end)

        %{state | running: running}

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
    if branch == default_branch_name() do
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

    Enum.reduce(state.running, state, fn {_issue_id, entry}, acc ->
      cond do
        not is_map(entry) -> acc
        State.deactivated_running_entry?(entry) -> acc
        true -> maybe_record_or_resume_for_topic(acc, entry, blocker_identifier, topic, metadata, unblock_key)
      end
    end)
  end

  @doc false
  @spec reconcile_pending_auto_resumes(State.t()) :: State.t()
  def reconcile_pending_auto_resumes(%State{} = state) do
    Enum.reduce(state.running, state, fn {_issue_id, entry}, acc ->
      case Map.get(entry, :pending_auto_resume) do
        %{} = hint when is_map(hint) ->
          maybe_drain_pending_auto_resume(acc, entry, hint)

        _ ->
          acc
      end
    end)
  end

  defp default_branch_name do
    case Config.settings!() do
      %{tracker: %{base_branch: name}} when is_binary(name) and name != "" -> name
      _ -> "main"
    end
  end

  defp maybe_record_or_resume_for_topic(state, entry, blocker_identifier, topic, metadata, unblock_key) do
    identifier = Map.get(entry, :identifier)

    cond do
      not is_binary(identifier) ->
        state

      identifier == blocker_identifier ->
        state

      consumed_unblock?(entry, unblock_key) ->
        state

      get_in(entry, [:blocker_branch_pushes, to_string(blocker_identifier)]) != metadata ->
        state

      subscribed_to_topic?(identifier, topic) and matching_blocker_pause?(entry, blocker_identifier) ->
        pause_generation = get_in(entry, [:blocker_pause, :generation])

        if State.paused_running_entry?(entry) do
          attempt_auto_resume(state, entry, identifier, blocker_identifier, topic, unblock_key, pause_generation)
        else
          stamp_pending_auto_resume(state, identifier, blocker_identifier, topic, unblock_key, pause_generation)
        end

      true ->
        state
    end
  end

  # Resume can fail when the concurrent-agent cap is already full —
  # the blockee would otherwise sit silently paused forever because
  # the explicit unblock event is consumed exactly once. Log a warning so
  # operators can see
  # the cap is blocking the resume, and stamp a hint on the entry so a
  # future reconcile tick (when a slot opens up) can drain the queue.
  defp attempt_auto_resume(state, entry, identifier, blocker_identifier, topic, unblock_key, pause_generation) do
    Logger.info("Auto-resume on blocker unblocked: blockee=#{identifier} blocker=#{blocker_identifier} topic=#{topic}")

    # operator?: false — an automated blocker resume must preserve a
    # duration-capped agent's cumulative overrun (no fresh budget).
    case Orchestrator.resume_paused_issue(state, entry, false) do
      {{:ok, :resumed}, next_state} ->
        finish_blocker_resume(next_state, identifier, unblock_key)

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
    cond do
      State.deactivated_running_entry?(entry) ->
        clear_pending_auto_resume(state, entry)

      not matching_hint_pause?(entry, hint) ->
        clear_pending_auto_resume(state, entry)

      not State.paused_running_entry?(entry) ->
        # The readiness event may arrive between subscription and the worker's
        # pause confirmation. Keep it durable until that transition completes.
        state

      true ->
        identifier = Map.get(entry, :identifier)
        blocker_identifier = Map.get(hint, :blocker_identifier)
        topic = Map.get(hint, :topic)

        # operator?: false — same automated path as attempt_auto_resume,
        # just deferred until a slot opened; preserve the duration overrun.
        case Orchestrator.resume_paused_issue(state, entry, false) do
          {{:ok, :resumed}, next_state} ->
            Logger.info("Auto-resume drained: blockee=#{identifier} blocker=#{blocker_identifier} topic=#{topic}")

            finish_blocker_resume(next_state, identifier, Map.get(hint, :unblock_key, topic))

          {{:error, _reason}, next_state} ->
            # Cap still full or another error — keep the hint for the
            # next reconcile tick.
            next_state
        end
    end
  end

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

  defp consumed_unblock?(entry, unblock_key) do
    entry
    |> Map.get(:consumed_unblocks, MapSet.new())
    |> MapSet.member?(unblock_key)
  end

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

  defp prepare_agent_pause(entry, event) do
    payload = event_payload(event)
    blocker_identifier = Map.get(payload, :blocker_identifier) || Map.get(payload, "blocker_identifier")
    reason = Map.get(payload, :reason) || Map.get(payload, "reason")

    if reason == "dependency" and (is_binary(blocker_identifier) or is_integer(blocker_identifier)) do
      generation = Map.get(entry, :blocker_pause_generation, 0) + 1

      entry
      |> Map.put(:paused_reason, :blocker_dependency)
      |> Map.put(:blocker_pause_generation, generation)
      |> Map.put(:blocker_pause, %{blocker_identifier: to_string(blocker_identifier), generation: generation})
    else
      entry
      |> Map.put(:paused_reason, :agent_pause_request)
      |> Map.delete(:blocker_pause)
      |> Map.delete(:pending_auto_resume)
    end
  end

  defp matching_blocker_pause?(entry, blocker_identifier),
    do: get_in(entry, [:blocker_pause, :blocker_identifier]) == to_string(blocker_identifier)

  defp matching_hint_pause?(entry, hint) do
    get_in(entry, [:blocker_pause, :blocker_identifier]) == Map.get(hint, :blocker_identifier) and
      get_in(entry, [:blocker_pause, :generation]) == Map.get(hint, :pause_generation) and
      Map.get(entry, :paused_reason) == :blocker_dependency
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

  defp maybe_record_blocker_push(entry, blocker_identifier, topic, metadata) when is_map(entry) do
    if subscribed_to_topic?(Map.get(entry, :identifier), topic) do
      pushes = Map.get(entry, :blocker_branch_pushes, %{})
      Map.put(entry, :blocker_branch_pushes, Map.put(pushes, to_string(blocker_identifier), metadata))
    else
      entry
    end
  end

  defp maybe_record_blocker_push(entry, _blocker_identifier, _topic, _metadata), do: entry

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
