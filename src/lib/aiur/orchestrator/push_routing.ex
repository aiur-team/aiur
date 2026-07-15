defmodule Aiur.Orchestrator.PushRouting do
  @moduledoc """
  Agent pause-on-request, default-branch push notification, sleeping state, and
  blocker auto-resume with pending_auto_resume drain.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.Config
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{PauseResume, State}

  @spec mark_sleeping(String.t()) :: :ok
  def mark_sleeping(issue_identifier), do: mark_sleeping(Aiur.Orchestrator, issue_identifier)

  @spec mark_sleeping(GenServer.server(), String.t()) :: :ok
  def mark_sleeping(server, issue_identifier) when is_binary(issue_identifier) do
    GenServer.cast(server, {:mark_sleeping, issue_identifier})
  end

  @spec apply_branch_push(State.t(), String.t()) :: State.t()
  def apply_branch_push(%State{} = state, blocker_identifier)
      when is_binary(blocker_identifier) do
    topic = "ticket." <> blocker_identifier <> ".branch.push"
    maybe_resume_blockees_on_push(state, blocker_identifier, topic)
  end

  @spec maybe_pause_on_request(State.t(), String.t() | integer()) :: State.t()
  def maybe_pause_on_request(%State{} = state, identifier) do
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
            {_reply, state} =
              PauseResume.request_pause(
                state,
                running_entry,
                Map.get(running_entry, :issue),
                :agent_pause_request
              )

            state
        end

      _ ->
        state
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

  @spec maybe_resume_blockees_on_push(State.t(), String.t() | integer(), String.t()) :: State.t()
  def maybe_resume_blockees_on_push(%State{} = state, blocker_identifier, topic) do
    Enum.reduce(state.running, state, fn {_issue_id, entry}, acc ->
      cond do
        not is_map(entry) -> acc
        not State.paused_running_entry?(entry) -> acc
        State.deactivated_running_entry?(entry) -> acc
        true -> maybe_resume_for_topic(acc, entry, blocker_identifier, topic)
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

  defp maybe_resume_for_topic(state, entry, blocker_identifier, topic) do
    identifier = Map.get(entry, :identifier)

    cond do
      not is_binary(identifier) ->
        state

      identifier == blocker_identifier ->
        state

      subscribed_to_topic?(identifier, topic) ->
        attempt_auto_resume(state, entry, identifier, blocker_identifier, topic)

      true ->
        state
    end
  end

  # Resume can fail when the concurrent-agent cap is already full —
  # the blockee would otherwise sit silently paused forever because
  # the push event is consumed exactly once and the firehose / ls-remote
  # dedup table prevents a re-emit. Log a warning so Executors can see
  # the cap is blocking the resume, and stamp a hint on the entry so a
  # future reconcile tick (when a slot opens up) can drain the queue.
  defp attempt_auto_resume(state, entry, identifier, blocker_identifier, topic) do
    Logger.info("Auto-resume on blocker push: blockee=#{identifier} blocker=#{blocker_identifier} topic=#{topic}")

    # operator?: false — an automated blocker resume must preserve a
    # duration-capped agent's cumulative overrun (no fresh budget).
    case Orchestrator.resume_paused_issue(state, entry, false) do
      {{:ok, :resumed}, next_state} ->
        next_state

      {{:error, :max_concurrent_agents_reached}, next_state} ->
        Logger.warning("Auto-resume deferred (cap full): blockee=#{identifier} blocker=#{blocker_identifier} topic=#{topic}; entry remains paused with pending_auto_resume hint")

        stamp_pending_auto_resume(next_state, identifier, blocker_identifier, topic)

      {{:error, reason}, next_state} ->
        Logger.warning("Auto-resume failed: blockee=#{identifier} blocker=#{blocker_identifier} reason=#{inspect(reason)}")

        next_state
    end
  end

  # Record a pending_auto_resume marker on the running entry so a
  # future tick (reconcile_pending_auto_resumes/1) can retry once a
  # slot opens up. Without this the cap-full case loses the push
  # signal and the blockee stays paused forever.
  defp stamp_pending_auto_resume(state, identifier, blocker_identifier, topic) do
    case State.find_running_by_identifier(state.running, identifier) do
      running_entry when is_map(running_entry) ->
        issue_id = get_in(running_entry, [:issue, Access.key(:id)])

        hint = %{
          blocker_identifier: blocker_identifier,
          topic: topic,
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
      not State.paused_running_entry?(entry) ->
        # Already resumed by another path (Executor chat, label flip);
        # clear the stale hint.
        clear_pending_auto_resume(state, entry)

      State.deactivated_running_entry?(entry) ->
        clear_pending_auto_resume(state, entry)

      true ->
        identifier = Map.get(entry, :identifier)
        blocker_identifier = Map.get(hint, :blocker_identifier)
        topic = Map.get(hint, :topic)

        # operator?: false — same automated path as attempt_auto_resume,
        # just deferred until a slot opened; preserve the duration overrun.
        case Orchestrator.resume_paused_issue(state, entry, false) do
          {{:ok, :resumed}, next_state} ->
            Logger.info("Auto-resume drained: blockee=#{identifier} blocker=#{blocker_identifier} topic=#{topic}")

            clear_pending_auto_resume(next_state, entry)

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
end
