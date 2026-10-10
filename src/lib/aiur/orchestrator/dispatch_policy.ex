defmodule Aiur.Orchestrator.DispatchPolicy do
  @moduledoc """
  Pure dispatch, load-gate, and issue-candidate policy for the orchestrator.
  """

  require Logger

  alias Aiur.{Issue, SystemCpu, SystemFileDescriptors}
  alias Aiur.BuildQueue.Hints
  alias Aiur.Orchestrator.DispatchPolicy.{Eligibility, Gates, IssueStates}
  alias Aiur.Orchestrator.{Slots, State}

  @type admission_reason :: Gates.admission_reason()

  @spec read_load(number() | nil) :: float() | :unavailable
  defdelegate read_load(threshold), to: Gates
  @spec read_load(number() | nil, number() | nil) :: float() | :unavailable
  defdelegate read_load(hard_threshold, target), to: Gates
  @spec read_cpu(number() | nil, number() | nil) :: SystemCpu.snapshot() | :unavailable
  defdelegate read_cpu(target, run_queue_threshold \\ nil), to: Gates

  @spec read_cpu(number() | nil, number() | nil, number() | nil) ::
          SystemCpu.snapshot() | :unavailable
  defdelegate read_cpu(target, run_queue_threshold, hard_threshold), to: Gates
  @spec read_memory(integer() | nil) :: non_neg_integer() | :unavailable
  defdelegate read_memory(threshold), to: Gates
  @spec read_file_descriptors() :: SystemFileDescriptors.sample_result()
  defdelegate read_file_descriptors(), to: Gates
  @spec read_build_status() :: map()
  defdelegate read_build_status(), to: Gates
  @spec read_provider_backends() :: [String.t()]
  defdelegate read_provider_backends(), to: Gates
  @spec read_github_quota() :: :available | {:hold, map()}
  defdelegate read_github_quota(), to: Gates
  @spec prewarm_gate(boolean(), atom() | {:error, term()}) :: :dispatch | :hold
  defdelegate prewarm_gate(eager?, phase), to: Gates
  @spec load_gate(number() | :unavailable, number() | nil, pos_integer()) :: :dispatch | :hold
  defdelegate load_gate(load, threshold, schedulers), to: Gates

  @spec load_admission_reason(
          number() | :unavailable,
          number() | nil,
          pos_integer(),
          SystemCpu.headroom() | :unavailable
        ) :: :dispatch | {:hold, admission_reason()}
  defdelegate load_admission_reason(load, threshold, schedulers, cpu_headroom), to: Gates
  @spec memory_gate(non_neg_integer() | :unavailable, integer() | nil) :: :dispatch | :hold
  defdelegate memory_gate(available_mb, threshold), to: Gates
  @spec fd_gate(SystemFileDescriptors.sample_result()) :: :dispatch | :hold
  defdelegate fd_gate(sample), to: Gates
  @spec fd_headroom_threshold(map()) :: pos_integer() | :unavailable
  defdelegate fd_headroom_threshold(sample), to: Gates
  @spec fd_headroom_percent() :: 10
  defdelegate fd_headroom_percent(), to: Gates
  @spec run_queue_gate(number() | :unavailable, pos_integer(), number() | nil) :: :dispatch | :hold
  defdelegate run_queue_gate(runnable, schedulers, threshold), to: Gates

  @spec run_queue_admission_reason(
          integer() | :unavailable,
          pos_integer(),
          number() | nil,
          SystemCpu.headroom() | :unavailable
        ) :: :dispatch | {:hold, admission_reason()}
  defdelegate run_queue_admission_reason(runnable, schedulers, threshold, cpu_headroom), to: Gates
  @spec build_gate(map()) :: :dispatch | :hold
  defdelegate build_gate(status), to: Gates
  @spec provider_gate([String.t()], keyword()) :: :dispatch | :hold
  defdelegate provider_gate(backends, opts \\ []), to: Gates
  @spec github_quota_gate(:available | {:hold, map()} | term()) :: :dispatch | :hold
  defdelegate github_quota_gate(status), to: Gates
  @spec admission_gate(map()) :: :dispatch | {:hold, admission_reason()}
  defdelegate admission_gate(probes), to: Gates

  @spec state_slots_available?(term(), term()) :: boolean()
  defdelegate state_slots_available?(issue, state), to: Eligibility
  @spec effective_state_limit(term(), State.t()) :: pos_integer()
  defdelegate effective_state_limit(issue_state, state), to: Eligibility
  @spec running_issue_count_for_state(term(), term()) :: non_neg_integer()
  defdelegate running_issue_count_for_state(running, issue_state), to: Eligibility
  @spec issue_not_paused?(Issue.t()) :: boolean()
  defdelegate issue_not_paused?(issue), to: Eligibility
  @spec issue_not_parked?(Issue.t()) :: boolean()
  defdelegate issue_not_parked?(issue), to: Eligibility
  @spec issue_routable_to_worker?(term()) :: boolean()
  defdelegate issue_routable_to_worker?(issue), to: Eligibility
  @spec issue_dispatch_authorized?(term()) :: boolean()
  defdelegate issue_dispatch_authorized?(issue), to: Eligibility
  @spec issue_dispatch_authorization_deferred?(term()) :: boolean()
  defdelegate issue_dispatch_authorization_deferred?(issue), to: Eligibility
  @spec todo_issue_blocked_by_non_terminal?(term(), MapSet.t()) :: boolean()
  defdelegate todo_issue_blocked_by_non_terminal?(issue, terminal_states), to: Eligibility
  @spec non_terminal_blockers(term(), MapSet.t()) :: [term()]
  defdelegate non_terminal_blockers(issue, terminal_states), to: Eligibility
  @spec describe_dependency_hold(term(), MapSet.t()) :: String.t()
  defdelegate describe_dependency_hold(issue, terminal_states), to: Eligibility
  @spec blocked_on_decision?(Issue.t(), MapSet.t() | :unavailable | nil) :: boolean()
  defdelegate blocked_on_decision?(issue, blocked), to: Eligibility

  @spec terminal_issue_state?(term(), MapSet.t()) :: boolean()
  defdelegate terminal_issue_state?(state_name, terminal_states), to: IssueStates
  @spec no_agent_work_state?(term()) :: boolean()
  defdelegate no_agent_work_state?(state_name), to: IssueStates
  @spec active_issue_state?(term(), MapSet.t()) :: boolean()
  defdelegate active_issue_state?(state_name, active_states), to: IssueStates
  @spec normalize_issue_state(term()) :: String.t()
  defdelegate normalize_issue_state(state_name), to: IssueStates
  @spec state_slug(term()) :: String.t() | nil
  defdelegate state_slug(state_name), to: IssueStates
  @spec resolve_state_labels([String.t()]) :: String.t() | nil
  defdelegate resolve_state_labels(state_labels), to: IssueStates
  @spec normalize_state_label(term()) :: String.t()
  defdelegate normalize_state_label(label), to: IssueStates
  @spec terminal_state_set() :: MapSet.t()
  defdelegate terminal_state_set(), to: IssueStates
  @spec active_state_set() :: MapSet.t()
  defdelegate active_state_set(), to: IssueStates

  @spec initial_load_envelope_limit(map()) :: pos_integer() | nil
  def initial_load_envelope_limit(%{target_load_average: nil}), do: nil
  def initial_load_envelope_limit(_agent), do: 1

  @spec load_envelope(integer() | nil, integer() | nil, number() | :unavailable, Aiur.Orchestrator.LoadEnvelope.envelope_options()) :: {pos_integer(), integer() | nil}
  defdelegate load_envelope(effective, last_decrease_ms, load, options), to: Aiur.Orchestrator.LoadEnvelope

  @spec update_load_envelope(State.t(), number() | :unavailable, number() | nil, pos_integer(), integer(), SystemCpu.snapshot() | :unavailable, boolean()) :: State.t()
  defdelegate update_load_envelope(state, load, target, schedulers, now_ms, cpu_snapshot, queued_work?), to: Aiur.Orchestrator.LoadEnvelope

  @spec sort_issues_for_dispatch([term()]) :: [term()]
  def sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {downstream_rank, position} = Hints.sort_key(issue.id)
        {downstream_rank, priority_rank(issue.priority), position, issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {0, priority_rank(nil), 0, issue_created_at_sort_key(nil), ""}
    end)
  end

  @spec priority_rank(term()) :: 1..5
  def priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  def priority_rank(_priority), do: 5

  @spec issue_created_at_sort_key(term()) :: integer()
  def issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  def issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  def issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  @spec should_dispatch_issue?(Issue.t(), State.t()) :: boolean()
  def should_dispatch_issue?(%Issue{} = issue, %State{} = state) do
    dispatch_decision(issue, state) == :dispatch
  end

  @spec should_dispatch_issue?(Issue.t(), State.t(), MapSet.t(), MapSet.t()) :: boolean()
  def should_dispatch_issue?(%Issue{} = issue, %State{} = state, active_states, terminal_states) do
    dispatch_decision(issue, state, active_states, terminal_states) == :dispatch
  end

  def should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  @type dispatch_decline_reason ::
          :invalid_issue
          | :contradictory_state_labels
          | :not_routable
          | :unauthorized
          | :paused
          | :parked
          | :inactive_state
          | :no_agent_work_state
          | :terminal_state
          | :dependency
          | :build_queue_hold
          | :blocked_on_decision
          | :already_running
          | :auto_resume_pending
          | :retry_backoff
          | :model_fallback_waiting
          | :workspace_ownership_waiting
          | :claimed_without_runtime
          | :state_capacity
          | :worker_capacity
          | :fleet_capacity

  # The single list of every reason `dispatch_decision/5` and
  # `manual_resume_decision/2` can decline with. Callers that translate a
  # decline reason (the operator resume path) enumerate this list in tests, so
  # a reason added to the policy without a translation fails a test instead of
  # crashing `aiur resume` with a FunctionClauseError (#2699). Keep it in the
  # same order as `t:dispatch_decline_reason/0`.
  @dispatch_decline_reasons [
    :invalid_issue,
    :contradictory_state_labels,
    :not_routable,
    :unauthorized,
    :paused,
    :parked,
    :inactive_state,
    :no_agent_work_state,
    :terminal_state,
    :dependency,
    :build_queue_hold,
    :blocked_on_decision,
    :already_running,
    :auto_resume_pending,
    :retry_backoff,
    :model_fallback_waiting,
    :workspace_ownership_waiting,
    :claimed_without_runtime,
    :state_capacity,
    :worker_capacity,
    :fleet_capacity
  ]

  @doc "Every reason the dispatch policy can decline an issue with."
  @spec dispatch_decline_reasons() :: [dispatch_decline_reason(), ...]
  def dispatch_decline_reasons, do: @dispatch_decline_reasons

  @spec dispatch_decision(term(), State.t()) :: :dispatch | {:skip, dispatch_decline_reason()}
  def dispatch_decision(issue, %State{} = state) do
    dispatch_decision(
      issue,
      state,
      active_state_set(),
      terminal_state_set(),
      state.blocked_ticket_ids
    )
  end

  @spec dispatch_decision(term(), State.t(), MapSet.t(), MapSet.t()) ::
          :dispatch | {:skip, dispatch_decline_reason()}
  def dispatch_decision(issue, %State{} = state, active_states, terminal_states) do
    dispatch_decision(issue, state, active_states, terminal_states, state.blocked_ticket_ids)
  end

  @spec dispatch_decision(term(), State.t(), MapSet.t(), MapSet.t(), MapSet.t() | :unavailable | nil) ::
          :dispatch | {:skip, dispatch_decline_reason()}
  def dispatch_decision(issue, %State{} = state, active_states, terminal_states, blocked_ticket_ids) do
    case dispatch_candidate_decision(issue, state, active_states, terminal_states, blocked_ticket_ids) do
      :dispatch -> if(Slots.available_slots(state) > 0, do: :dispatch, else: {:skip, :fleet_capacity})
      {:skip, _reason} = declined -> declined
    end
  end

  @doc false
  # Manual starts share every canonical eligibility and ownership check with
  # polling, but intentionally ignore slots reserved by paused agents. The
  # Executor may fill a genuinely free active slot while another agent remains
  # parked in the running map.
  @spec manual_resume_decision(term(), State.t()) ::
          :dispatch | {:skip, dispatch_decline_reason()}
  def manual_resume_decision(issue, %State{} = state) do
    case dispatch_candidate_decision(
           issue,
           state,
           active_state_set(),
           terminal_state_set(),
           state.blocked_ticket_ids
         ) do
      :dispatch ->
        if State.active_running_count(state.running) < Slots.max_concurrent_agent_limit(state),
          do: :dispatch,
          else: {:skip, :fleet_capacity}

      {:skip, _reason} = declined ->
        declined
    end
  end

  # All dispatch preconditions except the global active+paused slot reservation.
  # Polling layers `available_slots > 0` on top of this to honor paused-agent
  # slot holds; manual start paths (e.g., space on a queued ticket) instead
  # gate on `active < max` so the Executor can claim a free slot even when a
  # parallel paused agent is parked in the running map.
  @spec dispatch_candidate?(Issue.t(), State.t()) :: boolean()
  def dispatch_candidate?(%Issue{} = issue, %State{} = state) do
    dispatch_candidate_decision(
      issue,
      state,
      active_state_set(),
      terminal_state_set(),
      state.blocked_ticket_ids
    ) == :dispatch
  end

  @spec dispatch_candidate?(Issue.t(), State.t(), MapSet.t(), MapSet.t()) :: boolean()
  def dispatch_candidate?(
        %Issue{} = issue,
        %State{} = state,
        active_states,
        terminal_states
      ) do
    dispatch_candidate_decision(issue, state, active_states, terminal_states, state.blocked_ticket_ids) == :dispatch
  end

  @spec dispatch_candidate?(Issue.t(), State.t(), MapSet.t(), MapSet.t(), MapSet.t() | :unavailable | nil) ::
          boolean()
  def dispatch_candidate?(
        %Issue{} = issue,
        %State{} = state,
        active_states,
        terminal_states,
        blocked_ticket_ids
      ) do
    dispatch_candidate_decision(issue, state, active_states, terminal_states, blocked_ticket_ids) ==
      :dispatch
  end

  defp dispatch_candidate_decision(
         %Issue{} = issue,
         %State{} = state,
         active_states,
         terminal_states,
         blocked_ticket_ids
       ) do
    case issue_eligibility_decision(issue, active_states, terminal_states) do
      :dispatch -> dispatch_state_decision(issue, state, terminal_states, blocked_ticket_ids)
      {:skip, _reason} = declined -> declined
    end
  end

  defp dispatch_candidate_decision(
         _issue,
         _state,
         _active_states,
         _terminal_states,
         _blocked_ticket_ids
       ),
       do: {:skip, :invalid_issue}

  defp valid_issue_shape?(%Issue{id: id, identifier: identifier, title: title, state: state}) do
    is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state)
  end

  defp issue_eligibility_decision(%Issue{} = issue, active_states, terminal_states) do
    case issue_identity_decision(issue) do
      :dispatch -> issue_state_decision(issue, active_states, terminal_states)
      {:skip, _reason} = declined -> declined
    end
  end

  defp issue_identity_decision(%Issue{state_labels: [_, _ | _] = state_labels} = issue) do
    # A ticket carrying two `agent:*` state labels is a broken lifecycle state:
    # the fail-closed guard used to refuse it, silently dropping the ticket
    # from dispatch with no error and no alert (#2075). Resolve the pair to a
    # single deterministic state instead and continue the ordinary checks, so
    # the ticket is dispatchable rather than stranded. `resolve_state_labels/1`
    # makes `todo` win (a ticket that is also `todo` has no work for a `rework`
    # verdict to mean anything about); the poll-time heal in
    # `IssueSync.reconcile_contradictory_state_labels/3` also rewrites the
    # tracker so GitHub stops carrying both labels.
    winner = resolve_state_labels(state_labels)

    Logger.info(
      "Dispatch resolved contradictory state labels for issue_id=#{inspect(issue.id)} " <>
        "labels=#{inspect(state_labels)} -> #{inspect(winner)}"
    )

    issue_identity_decision(%{issue | state: winner, state_labels: [winner]})
  end

  defp issue_identity_decision(%Issue{} = issue) do
    cond do
      not valid_issue_shape?(issue) -> {:skip, :invalid_issue}
      not issue_routable_to_worker?(issue) -> {:skip, :not_routable}
      not issue_dispatch_authorized?(issue) -> {:skip, :unauthorized}
      not issue_not_paused?(issue) -> {:skip, :paused}
      not issue_not_parked?(issue) -> {:skip, :parked}
      true -> :dispatch
    end
  end

  defp issue_state_decision(%Issue{} = issue, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) -> {:skip, :terminal_state}
      no_agent_work_state?(issue.state) -> {:skip, :no_agent_work_state}
      not active_issue_state?(issue.state, active_states) -> {:skip, :inactive_state}
      true -> :dispatch
    end
  end

  defp dispatch_state_decision(issue, state, terminal_states, blocked_ticket_ids) do
    if Hints.held?(issue.id),
      do: {:skip, :build_queue_hold},
      else: dispatch_unheld_state_decision(issue, state, terminal_states, blocked_ticket_ids)
  end

  defp dispatch_unheld_state_decision(
         %Issue{} = issue,
         %State{} = state,
         terminal_states,
         blocked_ticket_ids
       ) do
    cond do
      blocked_on_decision?(issue, blocked_ticket_ids) -> {:skip, :blocked_on_decision}
      todo_issue_blocked_by_non_terminal?(issue, terminal_states) -> {:skip, :dependency}
      Map.has_key?(state.running, issue.id) -> {:skip, :already_running}
      Map.has_key?(state.auto_resume, issue.id) -> {:skip, :auto_resume_pending}
      MapSet.member?(state.claimed, issue.id) -> {:skip, claimed_decline_reason(state, issue.id)}
      not state_slots_available?(issue, state) -> {:skip, :state_capacity}
      not Slots.worker_slots_available?(state) -> {:skip, :worker_capacity}
      true -> :dispatch
    end
  end

  defp claimed_decline_reason(%State{} = state, issue_id) do
    cond do
      Map.has_key?(state.retry_attempts, issue_id) -> :retry_backoff
      MapSet.member?(state.model_fallback_waiting, issue_id) -> :model_fallback_waiting
      workspace_ownership_waiting?(state, issue_id) -> :workspace_ownership_waiting
      true -> :claimed_without_runtime
    end
  end

  defp workspace_ownership_waiting?(%State{} = state, issue_id) do
    state.dispatch_recovery.workspace_ownership.waits
    |> Map.values()
    |> Enum.any?(fn
      envelope when is_map(envelope) -> Map.get(envelope, :issue_id) == issue_id
      _other -> false
    end)
  end

  @spec queued_dispatch_demand?([Issue.t()], State.t()) :: boolean()
  def queued_dispatch_demand?(issues, %State{} = state) when is_list(issues) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    Enum.any?(
      issues,
      &dispatch_candidate?(&1, state, active_states, terminal_states, state.blocked_ticket_ids)
    )
  end

  @spec candidate_issue?(term(), MapSet.t(), MapSet.t()) :: boolean()
  def candidate_issue?(
        %Issue{
          id: id,
          identifier: identifier,
          title: title,
          state: state_name
        } = issue,
        active_states,
        terminal_states
      )
      when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_eligibility_decision(issue, active_states, terminal_states) == :dispatch
  end

  def candidate_issue?(_issue, _active_states, _terminal_states), do: false

  @spec retry_candidate_issue?(Issue.t(), MapSet.t()) :: boolean()
  def retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      not todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end
end
