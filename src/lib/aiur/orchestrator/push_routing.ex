defmodule Aiur.Orchestrator.PushRouting do
  @moduledoc """
  Agent pause-on-request, default-branch push notification, sleeping state, and
  generation-matched auto-resume for explicit blocker clearances and transient
  GitHub budget recovery. Both paths retain shared `pending_auto_resume` hints
  until the corresponding pause is confirmed or capacity becomes available.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{Commands, Config, Issue}
  alias Aiur.Events.BranchRefStore
  alias Aiur.Events.GithubKeys
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.PushRouting.{AutoResume, ClearedDependency}
  alias Aiur.Orchestrator.{Dispatcher, GithubBudgetPause, PauseResume, State}

  @doc false
  @spec reconcile_pending_auto_resumes(State.t()) :: State.t()
  defdelegate reconcile_pending_auto_resumes(state), to: AutoResume

  @doc false
  @spec finalize_applied_resume(State.t(), term()) :: State.t()
  defdelegate finalize_applied_resume(state, issue_id), to: AutoResume

  @doc false
  @spec maybe_resume_blockee_on_cleared_dependency(
          State.t(),
          map(),
          map(),
          :terminal | :removed,
          (Issue.t() -> {:ok, Issue.t()} | {:error, term()})
        ) :: State.t()
  defdelegate maybe_resume_blockee_on_cleared_dependency(state, blockee, blocker, clearance \\ :terminal, blocked_by_hydrator \\ &Dispatcher.default_blocked_by_hydrator/1), to: ClearedDependency

  @doc false
  @spec recheck_cleared_dependency_pauses(
          State.t(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()}),
          [term()],
          (Issue.t() -> {:ok, Issue.t()} | {:error, term()})
        ) :: State.t()
  defdelegate recheck_cleared_dependency_pauses(state, fetch_issue_states_fun, polled_issues \\ [], blocked_by_hydrator \\ &Dispatcher.default_blocked_by_hydrator/1), to: ClearedDependency

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
            request_agent_pause(state, running_entry, identifier, event)
        end

      _ ->
        state
    end
  end

  defp request_agent_pause(state, running_entry, identifier, event) do
    {running_entry, pause_reason} = prepare_agent_pause(running_entry, event)

    if nonblocking_question_pause?(identifier, pause_reason, event) do
      state
    else
      {_reply, state} = PauseResume.request_pause(state, running_entry, Map.get(running_entry, :issue), pause_reason)
      state
    end
  end

  defp nonblocking_question_pause?(identifier, :agent_pause_request, event) do
    payload = event_payload(event)
    reason = Map.get(payload, :reason) || Map.get(payload, "reason")

    reason not in ["operator_decision", :operator_decision, "upstream_merge", :upstream_merge] and
      Commands.nonblocking_question_pause?(to_string(identifier)) == {:ok, true}
  end

  defp nonblocking_question_pause?(_identifier, _pause_reason, _event), do: false

  @doc false
  @spec recover_github_budget_pauses(State.t(), integer()) :: State.t()
  def recover_github_budget_pauses(%State{} = state, now_ms \\ System.system_time(:millisecond)),
    do: GithubBudgetPause.recover_observed(state, now_ms)

  @doc false
  @spec recover_github_budget_pause(State.t(), String.t(), pos_integer(), integer()) :: State.t()
  def recover_github_budget_pause(%State{} = state, identifier, generation, now_ms \\ System.system_time(:millisecond)),
    do: GithubBudgetPause.recover_expired(state, identifier, generation, now_ms)

  @doc false
  @spec record_blocker_branch_push(State.t(), String.t() | integer(), map()) :: State.t()
  def record_blocker_branch_push(%State{} = state, blocker_identifier, event) do
    case validated_branch_metadata(blocker_identifier, event) do
      {:ok, metadata} ->
        case BranchRefStore.record_and_ready_unblock(metadata.ref, metadata.sha) do
          {:ok, %{} = pending_unblock} ->
            topic = "ticket.#{blocker_identifier}.agent.unblocked"
            unblock_key = topic <> ":" <> pending_unblock.sha
            AutoResume.resume_and_maybe_ack_unblock(state, blocker_identifier, topic, pending_unblock, unblock_key)

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
      :ready -> AutoResume.resume_and_maybe_ack_unblock(state, blocker_identifier, topic, metadata, unblock_key)
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
    |> Enum.reduce(state, &AutoResume.resume_or_record_merged_blockee(&2, &1, blocker_identifier, topic))
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
end
