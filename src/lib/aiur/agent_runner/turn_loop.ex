defmodule Aiur.AgentRunner.TurnLoop do
  @moduledoc false

  require Logger

  alias Aiur.AgentRunner.{
    Handoff,
    LocalGateCICache,
    MessageHandler,
    NoopWait,
    QueueDrain,
    SessionLifecycle,
    TurnCallbacks,
    TurnCompletion,
    TurnSupport
  }

  alias Aiur.AgentRunner.{
    RepeatedCommandGuard,
    RepeatedCommandStop,
    SessionResume,
    ToolExecutor,
    TurnAlerts,
    TurnPrompt,
    TurnStreams
  }

  alias Aiur.AgentTools.Dispatch
  alias Aiur.CodingAgent
  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Signal
  alias Aiur.Workspace
  alias Aiur.Workspace.WipPreservation

  @type worker_host :: String.t() | nil

  # A briefly overloaded orchestrator queue GenServer answers restore/fail/
  # consume with `{:error, :unavailable}` / `:timeout`. For the Codex recovery
  # restore that gates a clean replacement exit, retry that transient result a
  # bounded number of times before giving up, so a genuinely dead orchestrator
  # cannot spin the runner Task forever.

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
        ) :: :ok | {:completed, Issue.t()} | {:error, term()}
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

    app_session = Handoff.before_turn(app_session, turn_context)

    case Workspace.ensure_agent_support_before_turn(workspace, issue, worker_host) do
      :ok -> run_supported_turn(turn_context, app_session)
      {:error, _reason} = error -> refuse_unsupported_turn(turn_context, error)
    end
  end

  # A support refusal ends this runner turn. For an adopted active turn,
  # Handoff.adopt/4 stops the adopted session in its after block; restore the
  # delivered item so a replacement can retry after workspace support is fixed.
  defp refuse_unsupported_turn(%{orchestrator: orchestrator, issue: issue, opts: opts}, error) do
    TurnSupport.confirm_restore_for_replacement(orchestrator, issue, opts, error)
  end

  defp run_supported_turn(turn_context, app_session) do
    %{
      workspace: workspace,
      issue: issue,
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      orchestrator: orchestrator,
      worker_host: worker_host,
      turn_number: turn_number,
      max_turns: max_turns
    } = turn_context

    # Work that Aiur saved before it recreated this workspace (#2743) is
    # announced at the top of the next turn, with the restore commands.
    # The notice stays pending until a turn that carried it completes.
    {prompt, wip_notices} = Handoff.turn_prompt(turn_context)

    # The prompt is a no-op witness: two consecutive
    # continuation prompts differ only in `#N`, so an unchanged prompt means the
    # agent was handed no new input for this turn.
    turn_context = Map.put(turn_context, :prompt, prompt)
    Process.put(:handoff_turn_context, turn_context)

    callbacks =
      TurnCallbacks.build(
        app_session,
        issue,
        opts
        |> Keyword.put(:workspace, workspace)
        |> Keyword.put(:worker_host, worker_host)
        |> Keyword.put(:recipient, codex_update_recipient)
        |> Keyword.put(:orchestrator, orchestrator)
      )

    message_handler = callbacks.on_message

    MessageHandler.send_control_state(codex_update_recipient, issue, :working)
    aiur_turn_id = TurnStreams.open(issue)

    :ok = Dispatch.reset_turn_quotas()

    lifecycle_attempt_id = Keyword.get(opts, :telemetry_attempt_id)
    operation_id = "turn:#{turn_number}"

    Signal.lifecycle(issue.identifier, lifecycle_attempt_id, :implement, :start, %{
      operation_id: operation_id,
      turn_number: turn_number,
      backend: SessionLifecycle.session_backend_label(app_session)
    })

    agent_settings = Config.settings!().agent

    RepeatedCommandGuard.start_turn(
      repeat_threshold: agent_settings.max_repeated_identical_commands,
      command_cap: agent_settings.max_commands_per_turn,
      input_token_cap: agent_settings.max_input_tokens_per_turn,
      local_gate_wait_steer_minutes: agent_settings.local_gate_wait_steer_minutes,
      local_gate_wait_stop_minutes: agent_settings.local_gate_wait_stop_minutes,
      local_gate_ci_max_age_minutes: agent_settings.local_gate_ci_max_age_minutes,
      local_gate_ci_reader: fn -> LocalGateCICache.read(orchestrator, issue.identifier) end
    )

    result =
      try do
        coding_agent_run_turn(opts).(
          app_session,
          prompt,
          issue,
          handoff_orchestrator: orchestrator,
          on_message: message_handler,
          on_safe_checkpoint: callbacks.on_safe_checkpoint,
          on_operator_message: callbacks.on_operator_message,
          on_operator_response: callbacks.on_operator_response,
          tool_executor:
            ToolExecutor.build(issue, workspace, worker_host, app_session,
              attempt_id: lifecycle_attempt_id,
              rework_head_sha: Keyword.get(opts, :rework_head_sha)
            )
        )
      catch
        :throw, {:repeated_identical_command, command, count} ->
          {:error, {:repeated_identical_command, command, count}}

        :throw, {:green_ci_local_gate_wait, head_sha, pr_number, elapsed_minutes} ->
          {:error, {:green_ci_local_gate_wait, head_sha, pr_number, elapsed_minutes}}

        :throw, {:turn_cap, cap, count} ->
          {:error, {:turn_cap, cap, count}}
      after
        RepeatedCommandGuard.finish_turn()
      end

    complete_supported_turn(
      turn_context,
      app_session,
      result,
      %{
        issue: issue,
        lifecycle_attempt_id: lifecycle_attempt_id,
        operation_id: operation_id,
        turn_number: turn_number,
        codex_update_recipient: codex_update_recipient,
        aiur_turn_id: aiur_turn_id,
        wip_notices: wip_notices,
        worker_host: worker_host,
        max_turns: max_turns,
        message_handler: message_handler,
        orchestrator: orchestrator,
        workspace: workspace,
        opts: opts
      }
    )
  end

  defp complete_supported_turn(turn_context, app_session, result, context) do
    %{
      issue: issue,
      lifecycle_attempt_id: lifecycle_attempt_id,
      operation_id: operation_id,
      turn_number: turn_number,
      codex_update_recipient: codex_update_recipient,
      aiur_turn_id: aiur_turn_id,
      wip_notices: wip_notices,
      worker_host: worker_host,
      max_turns: max_turns,
      message_handler: message_handler,
      orchestrator: orchestrator,
      workspace: workspace,
      opts: opts
    } = context

    TurnSupport.record_implementation_end(issue, lifecycle_attempt_id, operation_id, turn_number, result)

    if turn_number == 1, do: SessionResume.track_resume_turn_start(app_session, issue.identifier, result)

    TurnStreams.close(issue, aiur_turn_id, TurnSupport.turn_done_reason(result))
    backend = SessionLifecycle.session_backend!(app_session)

    case result do
      {:ok, turn_session} ->
        SessionResume.fresh_turn_completed(app_session, issue.identifier)
        :ok = WipPreservation.mark_delivered(wip_notices)

        SessionResume.maybe_persist_turn_handle(
          app_session,
          turn_session,
          issue.identifier,
          worker_host
        )

        TurnSupport.best_effort_queue_bookkeeping(
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
                 codex_update_recipient,
                 opts
               ) do
          TurnCompletion.finalize_turn_completion(
            turn_context,
            app_session,
            turn_session,
            message_handler
          )
        end

      {:paused, pause_payload} ->
        Logger.info("Paused agent run for #{Aiur.AgentRunner.issue_context(issue)} session_id=#{pause_payload[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns_display(max_turns)}")

        with :ok <- TurnSupport.settle_paused_turn(turn_context, app_session, pause_payload, message_handler) do
          continue_after_resume(turn_context, app_session)
        end

      {:error, reason} = error ->
        case reason do
          {:repeated_identical_command, command, count} ->
            RepeatedCommandStop.stop_on_repeated_command(turn_context, command, count)

          {:green_ci_local_gate_wait, head_sha, pr_number, elapsed_minutes} ->
            RepeatedCommandStop.stop_on_green_ci_local_gate_wait(turn_context, head_sha, pr_number, elapsed_minutes)

          {:turn_cap, cap, count} ->
            RepeatedCommandStop.stop_on_turn_cap(turn_context, cap, count)

          _ ->
            settle_turn_error(turn_context, backend, reason, error)
        end
    end
  end

  @doc false
  @spec build_turn_prompt(Issue.t(), Path.t(), keyword(), pos_integer(), pos_integer() | nil) ::
          String.t()
  def build_turn_prompt(issue, workspace, opts, turn_number, max_turns) do
    TurnPrompt.build_turn_prompt(
      issue,
      Keyword.put(opts, :workspace, workspace),
      turn_number,
      max_turns
    )
  end

  # Provider-classified recoverable session failures must not fail the durable queue item: restore it and
  # let the top-level runner clean-exit so the orchestrator replaces the stale
  # session and a fresh transport redelivers the item once. The restore is the
  # gate — issue #1238 showed that best-effort swallowing of an
  # `{:error, :unavailable}` restore stranded the claimed item `:delivered`,
  # unclaimable by the replacement. Confirm the restore before reporting clean
  # recovery; non-recoverable provider failures keep the best-effort fail
  # settlement and its retry-exhaustion path.
  defp settle_turn_error(turn_context, backend, reason, error) do
    %{
      issue: issue,
      workspace: workspace,
      worker_host: worker_host,
      orchestrator: orchestrator,
      opts: opts
    } =
      turn_context

    if CodingAgent.recoverable_session_error?(backend, reason) do
      TurnSupport.confirm_restore_for_replacement(orchestrator, issue, opts, error)
    else
      TurnAlerts.maybe_emit_more_tokens_alert(issue, workspace, worker_host, reason)
      TurnAlerts.maybe_emit_route_failure_alert(issue, workspace, worker_host, reason)

      TurnSupport.best_effort_queue_bookkeeping(
        Aiur.Orchestrator.fail_delivered_queue_items(orchestrator, issue.identifier, reason),
        :fail,
        issue
      )

      error
    end
  end

  @doc false
  defdelegate turn_done_reason(result), to: TurnSupport

  @doc false
  defdelegate best_effort_queue_bookkeeping(result, op, issue), to: TurnSupport

  @doc false
  defdelegate confirm_restore_for_replacement(orchestrator, issue, opts, error), to: TurnSupport

  @doc false
  defdelegate confirm_restore_delivered(orchestrator, issue, opts \\ []), to: TurnSupport

  @doc false
  @spec noop_handoff(map(), Issue.t()) :: {:handoff, term()} | :none | {:error, term()}
  defdelegate noop_handoff(turn_context, issue), to: TurnCompletion

  @doc false
  @spec transition_agent_handoff(map(), Issue.t()) ::
          {:handoff, term()} | :none | {:error, term()}
  defdelegate transition_agent_handoff(turn_context, issue), to: TurnCompletion

  @doc false
  @spec noop_turn_cap(keyword()) :: pos_integer() | nil
  defdelegate noop_turn_cap(opts), to: TurnCompletion

  @doc false
  @spec return_completed(map(), Issue.t()) :: {:completed, Issue.t()}
  def return_completed(turn_context, %Issue{} = issue) when is_map(turn_context),
    do: {:completed, issue}

  @doc false
  defdelegate confirm_pause_containment(app_session), to: TurnSupport

  @doc false
  defdelegate settle_paused_turn(context, app_session, payload, message_handler, completed \\ nil),
    to: TurnSupport

  @doc false
  @spec continue_after_resume(map(), map()) :: :ok | {:completed, Issue.t()} | {:error, term()}
  def continue_after_resume(turn_context, app_session) do
    issue = turn_context.issue

    case continue_with_issue?(issue, turn_context.issue_state_fetcher) do
      {:continue, refreshed_issue}
      when is_nil(turn_context.max_turns) or turn_context.turn_number < turn_context.max_turns ->
        Logger.info(
          "aiur_autonomous_loop phase=recurse elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} turn=#{turn_context.turn_number + 1}/#{max_turns_display(turn_context.max_turns)} reason=resume"
        )

        # A resume is new input by definition (#2806): the operator message or
        # answered decision that released the pause is exactly the fresh input a
        # no-op run lacked, so the consecutive-no-op run starts over here.
        continue_issue_turn(
          %{
            turn_context
            | issue: refreshed_issue,
              turn_number: turn_context.turn_number + 1,
              opts:
                Keyword.put(
                  turn_context.opts,
                  :turn_progress,
                  NoopWait.progress_after_resume(turn_context)
                )
          },
          app_session
        )

      {:continue, refreshed_issue} ->
        Logger.info("aiur_autonomous_loop phase=max_turns_reached elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} reason=resume")

        return_completed(turn_context, refreshed_issue)

      {:done, refreshed_issue} ->
        Logger.info("aiur_autonomous_loop phase=done elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} reason=resume_inactive")

        return_completed(turn_context, refreshed_issue)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec continue_issue_turn(map(), map()) :: term()
  def continue_issue_turn(turn_context, app_session) do
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

  @doc false
  @spec continue_with_issue?(Issue.t(), fun()) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher)
      when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        refreshed_issue = %{refreshed_issue | optimistic_start: issue.optimistic_start}
        # The paused override parks a ticket even when its underlying state is active.
        if active_issue_state?(refreshed_issue.state) and not Issue.paused?(refreshed_issue) do
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

  def continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    not DispatchPolicy.no_agent_work_state?(normalized_state) and
      Enum.any?(
        Config.settings!().tracker.active_states,
        &(normalize_issue_state(&1) == normalized_state)
      )
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp coding_agent_run_turn(opts), do: Keyword.get(opts, :run_turn, &CodingAgent.run_turn/4)
end
