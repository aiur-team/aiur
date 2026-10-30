defmodule Aiur.Orchestrator.OverrideSuccessor do
  @moduledoc "Retires uncontinuable work before releasing one successor ticket."

  require Logger
  alias Aiur.{CodeHost, Commands, Config, Tracker}
  alias Aiur.Orchestrator.{AgentTeardown, IssueSync, State, TicketTransition, TrackerTasks}
  alias Aiur.Orchestrator.PauseResume.Resume

  @spec schedule(State.t(), map(), Aiur.Issue.t(), map() | nil, map(), keyword()) :: State.t()
  def schedule(state, decision, issue, entry, pr, opts) do
    key = {:override_successor, issue.id}

    if TrackerTasks.running?(state, key) do
      state
    else
      record = Commands.pending_override(decision)
      state = Keyword.get(opts, :stop_fun, &stop/3).(state, issue, entry)
      issue = %{issue | parked: true}
      state = IssueSync.remember_issue(state, issue)

      hold =
        (entry || %{identifier: issue.identifier, started_at: DateTime.utc_now()})
        |> Map.merge(%{issue: issue, pid: nil, ref: nil, control: %{status: :deactivated}, override_retirement: true})

      state = Resume.put_running_entry(state, issue.id, hold)

      TrackerTasks.run(state, key, fn -> reconcile(decision, record, pr, opts) end, fn current, result ->
        settle(current, decision, result, opts)
      end)
    end
  end

  defp stop(state, _issue, nil), do: state
  defp stop(state, _issue, %{override_retirement: true}), do: state
  defp stop(state, issue, _entry), do: AgentTeardown.terminate_running_issue(state, issue.id, false)

  @doc false
  @spec reconcile(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(decision, record, pr, opts) do
    prefix = Keyword.get_lazy(opts, :label_prefix, fn -> Config.settings!().tracker.github.label_prefix end)
    create = Keyword.get(opts, :successor_fun, &Commands.override_successor/4)
    close = Keyword.get(opts, :close_fun, &CodeHost.close_superseded_pull_request/2)
    comment = Keyword.get(opts, :comment_fun, &Tracker.create_comment/2)
    marker = Keyword.get(opts, :marker_fun, &marker/3)
    release = Keyword.get(opts, :release_fun, fn id -> release(id, prefix, opts) end)

    with :ok <- marker.(record.ticket.identifier, :add, "#{prefix}:parked"),
         {:ok, ticket} <- create.(decision, record, pr, opts),
         :ok <- close.(pr.number, ticket.identifier),
         :ok <- comment.(record.ticket.identifier, "superseded by ##{ticket.identifier}: #{record.resume_reason}"),
         :ok <- release.(ticket.identifier) do
      {:ok, ticket}
    end
  end

  defp marker(identifier, action, label), do: TicketTransition.write_marker(identifier, action, label, writer: :override_recovery)

  defp release(identifier, prefix, opts) do
    transition_opts = [writer: :override_recovery] ++ Keyword.take(opts, [:tracker])

    with :ok <- TicketTransition.write_state(identifier, "todo", transition_opts),
         do: TicketTransition.write_marker(identifier, :remove, "#{prefix}:parked", transition_opts)
  end

  defp settle(state, decision, {:ok, ticket}, opts) do
    case link_current(decision, ticket, opts) do
      :ok -> state
      {:error, reason} -> settle(state, decision, {:error, reason}, opts)
    end
  end

  defp settle(state, decision, {:error, reason}, opts) do
    Logger.warning("Override successor failed: command=#{decision.decision_id} reason=#{inspect(reason)}")

    Commands.request(
      %{
        question: "Recover override for ##{decision.ticket.identifier}?",
        blocking: false,
        authority: :supervisor_allowed,
        reversibility: :reversible,
        source_id: "override-recovery-#{decision.active_action_id}",
        context: %{
          long_context_markdown:
            "Command #{decision.decision_id} could not continue its old PR or release a successor: #{inspect(reason)}. The override remains queued; repair the branch or retire the old PR and release the parked successor."
        }
      },
      [
        ticket: %{identifier: "executor"},
        requester: %{kind: :executor, executor_id: "override-recovery"},
        source: %{agent_id: "executor", session_id: "override-recovery", event_id: decision.active_action_id}
      ],
      Keyword.get(opts, :decision_store, Commands.default_store())
    )

    state
  end

  defp link_current(decision, ticket, opts) do
    store = Keyword.get(opts, :decision_store, Commands.default_store())

    with {:ok, %{decision: current}} <- Commands.get(decision.decision_id, store: store) do
      same_target? = Commands.override_target_ticket(current).identifier == Commands.override_target_ticket(decision).identifier
      actions = if same_target?, do: Enum.uniq([decision.active_action_id, current.active_action_id]), else: [decision.active_action_id]
      link_actions(decision.decision_id, actions, ticket, store)
    end
  end

  defp link_actions(id, actions, ticket, store) do
    Enum.reduce_while(actions, :ok, fn action_id, :ok ->
      case Commands.record_command_fact(id, :override_successor_ticket, %{action_id: action_id, ticket: ticket}, server: store) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
