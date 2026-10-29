defmodule Aiur.Orchestrator.OverrideResume do
  @moduledoc "Admits journal-backed override resumes before ordinary candidate dispatch."

  require Logger
  alias Aiur.{Commands, Issue, Tracker}
  alias Aiur.Orchestrator.{ControlLifecycle, Dispatcher, DispatchPolicy, IssueSync, Slots, State, TrackerTasks}
  alias Aiur.Orchestrator.Dispatcher.{Capacity, HoldsAndAlerts}
  alias Aiur.Orchestrator.PauseResume.{QueuedDispatch, Resume}

  @spec schedule(State.t(), [Issue.t()]) :: State.t()
  def schedule(state, issues) do
    TrackerTasks.run(state, :override_resumes, &load/0, fn current, result ->
      current |> apply_loaded(result) |> HoldsAndAlerts.dispatch_or_hold(issues)
    end)
  end

  defp load do
    requests = waiting(Commands.list_decisions(Commands.default_store()))

    Enum.map(requests, fn decision ->
      identifier = decision.ticket.identifier
      {decision, Tracker.fetch_issue_states_by_ids([identifier]), Tracker.ticket_pull_request(identifier)}
    end)
  end

  @doc false
  @spec waiting([Aiur.Decision.t()]) :: [Aiur.Decision.t()]
  def waiting(decisions) do
    decisions
    |> Enum.filter(fn decision ->
      case Commands.pending_override(decision) do
        %{state: :queued, route: route} when route in [:resume_pending, :capacity_wait] -> true
        _ -> false
      end
    end)
    |> Enum.sort_by(&DateTime.to_unix(Commands.pending_override(&1).queued_at, :microsecond))
    |> Enum.uniq_by(& &1.ticket.identifier)
  end

  @doc false
  @spec apply_loaded(State.t(), term(), keyword()) :: State.t()
  def apply_loaded(state, result, opts \\ [])

  def apply_loaded(state, result, opts) when is_list(result) do
    Enum.reduce(result, state, fn
      {snapshot, {:ok, [%Issue{} = issue]}, {:ok, pr}}, current when is_nil(pr) or is_map(pr) ->
        if is_nil(pr) or Map.get(pr, :merged?) == false, do: apply_one(current, snapshot, issue, opts), else: current

      _, current ->
        current
    end)
  end

  def apply_loaded(state, error, _opts) do
    Logger.warning("Override resume lookup failed: #{inspect(error)}")
    state
  end

  defp apply_one(state, snapshot, issue, opts) do
    store = Keyword.get(opts, :decision_store, Commands.default_store())

    with {:ok, %{decision: decision}} <- Commands.get(snapshot.decision_id, store: store),
         true <- decision.active_action_id == snapshot.active_action_id,
         %{state: :queued} <- Commands.pending_override(decision) do
      entry = State.find_running_by_identifier(state.running, issue.identifier)
      entry = if entry, do: Map.put(entry, :issue, issue)
      current = put_issue(state, issue, entry)

      cond do
        Issue.parked?(issue) or Issue.paused?(issue) ->
          persist_wait(decision, :resume_pending, :operator_pause, store)
          Keyword.get(opts, :ask_fun, &ask_resume/2).(decision, store)
          current

        not eligible_issue?(issue) ->
          current

        current.globally_paused ->
          current

        active?(entry) ->
          current

        pending_resume?(current) ->
          current

        not admitted?(current, entry, opts) ->
          persist_wait(decision, :capacity_wait, :capacity, store)
          current

        true ->
          case persist_wait(decision, :resume_pending, :eligible, store) do
            :ok ->
              {_reply, next} = Keyword.get(opts, :resume_fun, &resume/3).(current, issue, entry)
              next

            {:error, _} ->
              current
          end
      end
    else
      _stale_or_unavailable -> state
    end
  end

  defp eligible_issue?(issue) do
    terminal = DispatchPolicy.terminal_state_set()

    DispatchPolicy.issue_routable_to_worker?(issue) and DispatchPolicy.issue_dispatch_authorized?(issue) and
      DispatchPolicy.active_issue_state?(issue.state, DispatchPolicy.active_state_set()) and
      not DispatchPolicy.terminal_issue_state?(issue.state, terminal) and
      not DispatchPolicy.issue_held_by_dependency?(issue, terminal)
  end

  defp admitted?(state, entry, opts) do
    fleet? = if entry, do: Slots.resume_fleet_slot_available?(state, entry), else: Slots.available_slots(state) > 0
    # Admission may reuse this worker's reserved pause slot; never reserve it twice.
    admission_state = if entry, do: elem(State.pop_running_entry(state, entry.issue.id), 1), else: state
    admission = Keyword.get(opts, :admission_fun, &Capacity.auto_resume_admission/1)
    fleet? and admission.(admission_state) == :dispatch
  end

  defp active?(nil), do: false
  defp active?(entry), do: State.active_running_entry?(entry) and not State.sleeping_running_entry?(entry)

  # A control resume is not yet an active slot. Serialize until its receipt so
  # two released CI-wait reservations cannot both consume the last fleet slot.
  defp pending_resume?(state) do
    Enum.any?(state.running, fn {id, _} ->
      match?(%{action: :resume}, ControlLifecycle.current_pending(state.control_lifecycle, id))
    end)
  end

  defp resume(state, issue, nil) do
    with :ok <- QueuedDispatch.queued_issue_resumability(state, issue) do
      Dispatcher.dispatch_prevalidated_issue(state, issue)
    else
      error -> {error, state}
    end
  end

  defp resume(state, _issue, entry), do: Resume.do_resume_running_issue(state, entry)

  defp put_issue(state, issue, nil), do: IssueSync.remember_issue(state, issue)
  defp put_issue(state, issue, entry), do: Resume.put_running_entry(state, issue.id, entry)

  defp persist_wait(decision, route, reason, store) do
    record = Commands.pending_override(decision)

    if record.route != route or Map.get(record, :resume_reason) != reason do
      case Commands.record_command_fact(decision.decision_id, :override_resume_state, %{action_id: decision.active_action_id, route: route, reason: reason}, server: store) do
        {:ok, _} ->
          :ok

        {:error, error} ->
          Logger.warning("Override resume state persistence failed: #{inspect(error)}")
          {:error, error}
      end
    else
      :ok
    end
  end

  defp ask_resume(decision, store) do
    identifier = decision.ticket.identifier
    source_id = "override-resume-#{identifier}"

    Commands.request(
      %{
        question: "Resume ##{identifier} to apply the override?",
        options: [%{id: "resume", label: "Resume the existing worker"}, %{id: "keep", label: "Keep the ticket parked"}],
        authority: :supervisor_allowed,
        reversibility: :reversible,
        blocking: false,
        source_id: source_id,
        context: %{
          long_context_markdown:
            "Command #{decision.decision_id} has a pending override. The ticket has an explicit parked or paused label. To apply it, resume this same ticket through the normal operator resume control. Without a resume it stays parked; no replacement ticket is created."
        }
      },
      [
        ticket: %{identifier: "executor"},
        requester: %{kind: :executor, executor_id: "override-resume", ticket: identifier},
        source: %{agent_id: "executor", session_id: "override-resume", event_id: source_id}
      ],
      store
    )
  end
end
