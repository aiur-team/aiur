defmodule Aiur.AgentRunner.TurnSupport do
  @moduledoc false

  require Logger

  alias Aiur.AgentRunner.{MessageHandler, QueueDrain, SessionLifecycle, TurnAlerts}
  alias Aiur.Issue
  alias Aiur.Signal

  @restore_confirm_attempts 5
  @restore_confirm_backoff_ms 250

  @spec turn_done_reason(term()) :: :done | :paused | :input_required | {:failed, term()}
  def turn_done_reason({:ok, _session}), do: :done

  def turn_done_reason({:paused, %{control: %{request_id: id, generation: generation}}})
      when is_integer(id) and is_integer(generation),
      do: :paused

  def turn_done_reason({:paused, _payload}), do: :input_required
  def turn_done_reason({:error, reason}), do: {:failed, reason}
  def turn_done_reason(_), do: :done

  @spec record_implementation_end(Issue.t(), term(), String.t(), pos_integer(), term()) :: :ok
  def record_implementation_end(issue, attempt_id, operation_id, turn_number, result) do
    {outcome, reason_class} =
      case result do
        {:ok, _session} -> {:success, nil}
        {:paused, _payload} -> {:paused, nil}
        {:error, reason} -> {:failed, Signal.reason_class(reason)}
      end

    Signal.lifecycle(issue.identifier, attempt_id, :implement, :end, %{
      operation_id: operation_id,
      turn_number: turn_number,
      outcome: outcome,
      reason_class: reason_class
    })
  end

  @spec best_effort_queue_bookkeeping(:ok | {:error, term()}, atom(), Issue.t()) :: :ok
  def best_effort_queue_bookkeeping(:ok, _op, _issue), do: :ok

  def best_effort_queue_bookkeeping({:error, reason}, op, issue) do
    Logger.warning("Orchestrator #{op}_delivered_queue_items unavailable for #{Aiur.AgentRunner.issue_context(issue)}: #{inspect(reason)}; continuing without crashing the agent")

    :ok
  end

  @spec confirm_restore_for_replacement(GenServer.server(), Issue.t(), keyword(), {:error, term()}) ::
          {:error, term()}
  def confirm_restore_for_replacement(orchestrator, issue, opts, recoverable_error) do
    case confirm_restore_delivered(orchestrator, issue, opts) do
      :ok -> recoverable_error
      {:error, _reason} = restore_error -> restore_error
    end
  end

  @spec confirm_restore_delivered(GenServer.server(), Issue.t(), keyword()) :: :ok | {:error, term()}
  def confirm_restore_delivered(orchestrator, issue, opts \\ []) do
    attempts = Keyword.get(opts, :restore_confirm_attempts, @restore_confirm_attempts)
    backoff_ms = Keyword.get(opts, :restore_confirm_backoff_ms, @restore_confirm_backoff_ms)
    confirm_restore_delivered(orchestrator, issue, attempts, backoff_ms)
  end

  defp confirm_restore_delivered(orchestrator, issue, attempts, backoff_ms) do
    case Aiur.Orchestrator.restore_delivered_queue_items(orchestrator, issue.identifier) do
      :ok ->
        :ok

      {:error, reason} when attempts > 1 ->
        Logger.warning("Codex recovery restore unavailable for #{Aiur.AgentRunner.issue_context(issue)}: #{inspect(reason)}; retrying before replacement (#{attempts - 1} attempt(s) left)")

        if backoff_ms > 0, do: Process.sleep(backoff_ms)
        confirm_restore_delivered(orchestrator, issue, attempts - 1, backoff_ms)

      {:error, reason} ->
        Logger.error(
          "Codex recovery restore could not be confirmed for #{Aiur.AgentRunner.issue_context(issue)}: #{inspect(reason)}; refusing to report clean recovery so the queue item is not stranded delivered"
        )

        {:error, {:queue_restore_unconfirmed, reason}}
    end
  end

  @spec confirm_pause_containment(map()) :: :ok
  def confirm_pause_containment(app_session),
    do: Aiur.PauseContainment.confirm(Map.get(app_session, :containment))

  @spec settle_paused_turn(map(), map(), map(), fun(), (-> term()) | nil) :: :ok | {:error, term()}
  def settle_paused_turn(context, app_session, pause_payload, message_handler, completed \\ nil) do
    %{
      issue: issue,
      workspace: workspace,
      worker_host: worker_host,
      orchestrator: orchestrator,
      codex_update_recipient: recipient,
      opts: opts
    } = context

    confirm_pause_containment(app_session)

    TurnAlerts.maybe_emit_usage_limit_alert(
      issue,
      workspace,
      worker_host,
      Map.put(pause_payload, :backend, SessionLifecycle.session_backend_label(app_session))
    )

    settle_delivered_queue_item(orchestrator, issue, pause_payload, completed)
    Aiur.AgentRunner.write_pause_log(workspace, worker_host)

    MessageHandler.send_control_state(
      recipient,
      issue,
      :paused,
      pause_payload(app_session, workspace, pause_payload)
    )

    QueueDrain.wait_for_operator_message(
      app_session,
      issue,
      message_handler,
      orchestrator,
      recipient,
      opts
    )
  end

  defp settle_delivered_queue_item(orchestrator, issue, %{native_terminal: :completed}, completed) do
    if completed do
      completed.()
    else
      best_effort_queue_bookkeeping(
        Aiur.Orchestrator.consume_delivered_queue_items(orchestrator, issue.identifier),
        :consume,
        issue
      )
    end
  end

  defp settle_delivered_queue_item(orchestrator, issue, _payload, _completed) do
    best_effort_queue_bookkeeping(
      Aiur.Orchestrator.restore_delivered_queue_items(orchestrator, issue.identifier),
      :restore,
      issue
    )
  end

  defp pause_payload(session, cwd, payload) do
    Map.merge(payload, %{
      session_id: Map.get(session, :thread_id),
      account_name: Map.get(session, :account_name),
      cwd: cwd
    })
  end
end
