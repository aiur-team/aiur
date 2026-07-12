defmodule Aiur.AgentRunner.TurnLoop do
  @moduledoc false

  require Logger

  alias Aiur.AgentRunner.{CheckpointDelivery, MessageHandler, QueueDrain, SessionLifecycle}
  alias Aiur.AgentRunner.{SessionResume, ToolExecutor, TurnAlerts, TurnPrompt, TurnStreams}
  alias Aiur.Codex.DynamicTool
  alias Aiur.CodingAgent
  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.RunTelemetry.Lifecycle

  @type worker_host :: String.t() | nil

  @doc false
  @spec run_turns(
          map(),
          Path.t(),
          Issue.t(),
          pid() | nil,
          keyword(),
          fun(),
          GenServer.server(),
          worker_host(),
          pos_integer(),
          pos_integer() | nil
        ) :: :ok | {:error, term()}
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  def run_turns(
        app_session,
        workspace,
        issue,
        codex_update_recipient,
        opts,
        issue_state_fetcher,
        orchestrator,
        worker_host,
        turn_number,
        max_turns
      ) do
    turn_context = %{
      workspace: workspace,
      issue: issue,
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      orchestrator: orchestrator,
      worker_host: worker_host,
      turn_number: turn_number,
      max_turns: max_turns
    }

    prompt = TurnPrompt.build_turn_prompt(issue, opts, turn_number, max_turns)

    message_handler =
      MessageHandler.build(
        codex_update_recipient,
        issue,
        workspace,
        worker_host,
        SessionLifecycle.session_backend(app_session),
        nil,
        attempt_id: Keyword.get(opts, :telemetry_attempt_id)
      )

    safe_checkpoint_handler = CheckpointDelivery.safe_checkpoint_handler(issue, orchestrator)

    MessageHandler.send_control_state(codex_update_recipient, issue, :working)
    aiur_turn_id = TurnStreams.open(issue)

    :ok = DynamicTool.reset_turn_quotas()

    lifecycle_attempt_id = Keyword.get(opts, :telemetry_attempt_id)
    operation_id = "turn:#{turn_number}"

    Lifecycle.record(issue.identifier, lifecycle_attempt_id, :implement, :start, %{
      operation_id: operation_id,
      turn_number: turn_number,
      backend: SessionLifecycle.session_backend(app_session)
    })

    result =
      CodingAgent.run_turn(
        app_session,
        prompt,
        issue,
        on_message: message_handler,
        on_safe_checkpoint: safe_checkpoint_handler,
        on_operator_message: CheckpointDelivery.operator_immediate_handler(issue, orchestrator),
        tool_executor: ToolExecutor.build(issue, workspace, worker_host)
      )

    record_implementation_end(issue, lifecycle_attempt_id, operation_id, turn_number, result)

    TurnStreams.close(issue, aiur_turn_id, turn_done_reason(result))

    case result do
      {:ok, turn_session} ->
        SessionResume.maybe_persist_turn_handle(
          app_session,
          turn_session,
          issue.identifier,
          worker_host
        )

        best_effort_queue_bookkeeping(
          Aiur.Orchestrator.consume_delivered_queue_items(orchestrator, issue.identifier),
          :consume,
          issue
        )

        with :ok <-
               QueueDrain.drain_operator_messages(
                 app_session,
                 issue,
                 message_handler,
                 orchestrator,
                 codex_update_recipient
               ) do
          finalize_turn_completion(turn_context, app_session, turn_session)
        end

      {:paused, pause_payload} ->
        Aiur.PauseContainment.confirm(Map.get(app_session, :containment))

        Logger.info("Paused agent run for #{Aiur.AgentRunner.issue_context(issue)} session_id=#{pause_payload[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns_display(max_turns)}")

        TurnAlerts.maybe_emit_usage_limit_alert(
          issue,
          workspace,
          worker_host,
          Map.put(pause_payload, :backend, SessionLifecycle.session_backend(app_session))
        )

        best_effort_queue_bookkeeping(
          Aiur.Orchestrator.restore_delivered_queue_items(orchestrator, issue.identifier),
          :restore,
          issue
        )

        Aiur.AgentRunner.write_pause_log(workspace, worker_host)
        MessageHandler.send_control_state(codex_update_recipient, issue, :paused, pause_payload)
        wait_for_resume(turn_context, app_session, message_handler)

      {:error, reason} ->
        TurnAlerts.maybe_emit_more_tokens_alert(issue, workspace, worker_host, reason)

        best_effort_queue_bookkeeping(
          Aiur.Orchestrator.fail_delivered_queue_items(orchestrator, issue.identifier, reason),
          :fail,
          issue
        )

        {:error, reason}
    end
  end

  @doc false
  @spec turn_done_reason(term()) :: :done | :input_required | {:failed, term()}
  def turn_done_reason({:ok, _session}), do: :done
  def turn_done_reason({:paused, _payload}), do: :input_required
  def turn_done_reason({:error, reason}), do: {:failed, reason}
  def turn_done_reason(_), do: :done

  defp record_implementation_end(issue, attempt_id, operation_id, turn_number, result) do
    {outcome, reason_class} =
      case result do
        {:ok, _session} -> {:success, nil}
        {:paused, _payload} -> {:paused, nil}
        {:error, reason} -> {:failed, Lifecycle.reason_class(reason)}
      end

    Lifecycle.record(issue.identifier, attempt_id, :implement, :end, %{
      operation_id: operation_id,
      turn_number: turn_number,
      outcome: outcome,
      reason_class: reason_class
    })
  end

  @doc false
  @spec best_effort_queue_bookkeeping(:ok | {:error, term()}, atom(), Issue.t()) :: :ok
  def best_effort_queue_bookkeeping(:ok, _op, _issue), do: :ok

  @doc false
  def best_effort_queue_bookkeeping({:error, reason}, op, issue) do
    Logger.warning("Orchestrator #{op}_delivered_queue_items unavailable for #{Aiur.AgentRunner.issue_context(issue)}: #{inspect(reason)}; continuing without crashing the agent")

    :ok
  end

  defp finalize_turn_completion(turn_context, app_session, turn_session) do
    %{
      workspace: workspace,
      issue: issue,
      issue_state_fetcher: issue_state_fetcher,
      turn_number: turn_number,
      max_turns: max_turns
    } = turn_context

    Logger.info("Completed agent run for #{Aiur.AgentRunner.issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns_display(max_turns)}")

    case continue_with_issue?(issue, issue_state_fetcher) do
      {:continue, refreshed_issue} when is_nil(max_turns) or turn_number < max_turns ->
        Logger.info(
          "aiur_autonomous_loop phase=recurse elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} turn=#{turn_number + 1}/#{max_turns_display(max_turns)} reason=turn_completed"
        )

        Logger.info("Continuing agent run for #{Aiur.AgentRunner.issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns_display(max_turns)}")

        continue_issue_turn(
          %{turn_context | issue: refreshed_issue, turn_number: turn_number + 1},
          app_session
        )

      {:continue, refreshed_issue} ->
        Logger.info("aiur_autonomous_loop phase=max_turns_reached elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} turn=#{turn_number}/#{max_turns}")

        Logger.info("Reached agent.max_turns for #{Aiur.AgentRunner.issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

        :ok

      {:done, refreshed_issue} ->
        Logger.info("aiur_autonomous_loop phase=done elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} reason=issue_inactive")

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_for_resume(turn_context, app_session, message_handler) do
    %{
      issue: issue,
      orchestrator: orchestrator,
      codex_update_recipient: codex_update_recipient
    } = turn_context

    with :ok <-
           QueueDrain.wait_for_operator_message(
             app_session,
             issue,
             message_handler,
             orchestrator,
             codex_update_recipient
           ) do
      case continue_with_issue?(issue, turn_context.issue_state_fetcher) do
        {:continue, refreshed_issue}
        when is_nil(turn_context.max_turns) or turn_context.turn_number < turn_context.max_turns ->
          Logger.info(
            "aiur_autonomous_loop phase=recurse elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} turn=#{turn_context.turn_number + 1}/#{max_turns_display(turn_context.max_turns)} reason=resume"
          )

          continue_issue_turn(
            %{turn_context | issue: refreshed_issue, turn_number: turn_context.turn_number + 1},
            app_session
          )

        {:continue, refreshed_issue} ->
          Logger.info("aiur_autonomous_loop phase=max_turns_reached elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} reason=resume")

          :ok

        {:done, refreshed_issue} ->
          Logger.info("aiur_autonomous_loop phase=done elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} reason=resume_inactive")

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp continue_issue_turn(turn_context, app_session) do
    run_turns(
      app_session,
      turn_context.workspace,
      turn_context.issue,
      turn_context.codex_update_recipient,
      turn_context.opts,
      turn_context.issue_state_fetcher,
      turn_context.orchestrator,
      turn_context.worker_host,
      turn_context.turn_number,
      turn_context.max_turns
    )
  end

  # nil max_turns = uncapped: logs show the turn count over "∞", and the
  # continuation prompt omits the "of M" entirely.
  @doc false
  @spec max_turns_display(pos_integer() | nil) :: String.t()
  def max_turns_display(nil), do: "∞"
  def max_turns_display(max_turns), do: Integer.to_string(max_turns)

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end
end
