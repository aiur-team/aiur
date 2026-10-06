defmodule Aiur.AgentRunner.TurnLoop do
  @moduledoc false

  require Logger

  alias Aiur.AgentRunner.{MessageHandler, QueueDrain, SessionLifecycle, TurnCallbacks}
  alias Aiur.AgentRunner.{SessionResume, ToolExecutor, TurnAlerts, TurnProgress, TurnPrompt, TurnStreams}
  alias Aiur.Codex.DynamicTool
  alias Aiur.CodingAgent
  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.RunTelemetry.Lifecycle
  alias Aiur.Workspace

  @type worker_host :: String.t() | nil

  # A briefly overloaded orchestrator queue GenServer answers restore/fail/
  # consume with `{:error, :unavailable}` / `:timeout`. For the Codex recovery
  # restore that gates a clean replacement exit, retry that transient result a
  # bounded number of times before giving up, so a genuinely dead orchestrator
  # cannot spin the runner Task forever.
  @restore_confirm_attempts 5
  @restore_confirm_backoff_ms 250

  # #2806: a run of consecutive turns that changed nothing observable is
  # widened before it is stopped, so a mislabelled ticket costs tens of seconds
  # rather than a turn every seven seconds while it is still recoverable.
  @noop_backoff_step_ms 15_000
  @noop_backoff_ceiling_ms 60_000

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

    # #2697: never start a turn (first, continuation or post-resume) while the
    # workspace lacks the gh shim, gh config or quota dir the agent env names.
    # Repair happens here; a refused turn never reaches the provider.
    case Workspace.ensure_agent_support_before_turn(workspace, issue, worker_host) do
      :ok -> run_supported_turn(turn_context, app_session)
      {:error, _reason} = error -> refuse_unsupported_turn(turn_context, error)
    end
  end

  # The turn never started, so any delivered queue item goes back to pending
  # through the confirmed restore boundary instead of being failed.
  defp refuse_unsupported_turn(%{orchestrator: orchestrator, issue: issue, opts: opts}, error),
    do: confirm_restore_for_replacement(orchestrator, issue, opts, error)

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

    prompt = TurnPrompt.build_turn_prompt(issue, opts, turn_number, max_turns)
    # The prompt is one of the three no-op witnesses (#2806): two consecutive
    # continuation prompts differ only in `#N`, so an unchanged prompt means the
    # agent was handed no new input for this turn.
    turn_context = Map.put(turn_context, :prompt, prompt)

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

    :ok = DynamicTool.reset_turn_quotas()

    lifecycle_attempt_id = Keyword.get(opts, :telemetry_attempt_id)
    operation_id = "turn:#{turn_number}"

    Lifecycle.record(issue.identifier, lifecycle_attempt_id, :implement, :start, %{
      operation_id: operation_id,
      turn_number: turn_number,
      backend: SessionLifecycle.session_backend_label(app_session)
    })

    result =
      coding_agent_run_turn(opts).(
        app_session,
        prompt,
        issue,
        on_message: message_handler,
        on_safe_checkpoint: callbacks.on_safe_checkpoint,
        on_operator_message: callbacks.on_operator_message,
        on_operator_response: callbacks.on_operator_response,
        tool_executor: ToolExecutor.build(issue, workspace, worker_host, app_session, attempt_id: lifecycle_attempt_id)
      )

    record_implementation_end(issue, lifecycle_attempt_id, operation_id, turn_number, result)

    TurnStreams.close(issue, aiur_turn_id, turn_done_reason(result))
    backend = SessionLifecycle.session_backend!(app_session)

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
                 codex_update_recipient,
                 opts
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
          Map.put(pause_payload, :backend, SessionLifecycle.session_backend_label(app_session))
        )

        if pause_payload[:native_terminal] == :completed do
          best_effort_queue_bookkeeping(
            Aiur.Orchestrator.consume_delivered_queue_items(orchestrator, issue.identifier),
            :consume,
            issue
          )
        else
          best_effort_queue_bookkeeping(
            Aiur.Orchestrator.restore_delivered_queue_items(orchestrator, issue.identifier),
            :restore,
            issue
          )
        end

        Aiur.AgentRunner.write_pause_log(workspace, worker_host)
        MessageHandler.send_control_state(codex_update_recipient, issue, :paused, pause_payload)
        wait_for_resume(turn_context, app_session, message_handler)

      {:error, reason} = error ->
        settle_turn_error(turn_context, backend, reason, error)
    end
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
    %{issue: issue, workspace: workspace, worker_host: worker_host, orchestrator: orchestrator, opts: opts} =
      turn_context

    if CodingAgent.recoverable_session_error?(backend, reason) do
      confirm_restore_for_replacement(orchestrator, issue, opts, error)
    else
      TurnAlerts.maybe_emit_more_tokens_alert(issue, workspace, worker_host, reason)
      TurnAlerts.maybe_emit_route_failure_alert(issue, workspace, worker_host, reason)

      best_effort_queue_bookkeeping(
        Aiur.Orchestrator.fail_delivered_queue_items(orchestrator, issue.identifier, reason),
        :fail,
        issue
      )

      error
    end
  end

  @doc false
  @spec turn_done_reason(term()) :: :done | :paused | :input_required | {:failed, term()}
  def turn_done_reason({:ok, _session}), do: :done

  def turn_done_reason({:paused, %{control: %{request_id: id, generation: generation}}})
      when is_integer(id) and is_integer(generation), do: :paused

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

  # The one confirmed restore-and-replace boundary shared by the primary-turn
  # (`run_turns`) and queue-drain (`run_recorded_queue_item_turn`) seams. It
  # returns the original recoverable error — the clean-replacement-exit signal —
  # ONLY after the delivered queue item is durably restored to pending. If the
  # orchestrator restore RPC never confirms, it surfaces a non-recoverable
  # `:queue_restore_unconfirmed` error instead of faking clean recovery, so the
  # claimed item is never silently stranded `:delivered`.
  @doc false
  @spec confirm_restore_for_replacement(GenServer.server(), Issue.t(), keyword(), {:error, term()}) ::
          {:error, term()}
  def confirm_restore_for_replacement(orchestrator, issue, opts, recoverable_error) do
    case confirm_restore_delivered(orchestrator, issue, opts) do
      :ok -> recoverable_error
      {:error, _reason} = restore_error -> restore_error
    end
  end

  @doc false
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
        continue_unless_noop_bound(turn_context, app_session, refreshed_issue)

      {:continue, refreshed_issue} ->
        Logger.info("aiur_autonomous_loop phase=max_turns_reached elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} turn=#{turn_number}/#{max_turns}")

        Logger.info("Reached agent.max_turns for #{Aiur.AgentRunner.issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

        return_completed(turn_context, refreshed_issue)

      {:done, refreshed_issue} ->
        Logger.info("aiur_autonomous_loop phase=done elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} reason=issue_inactive")

        compact_for_review_handoff(turn_context, app_session, refreshed_issue)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compact_for_review_handoff(turn_context, %{backend: "codex"} = app_session, issue) do
    compaction_config = Aiur.AgentCompaction.Config.settings()
    agent_total_tokens = token_count_for_compaction(turn_context, issue, compaction_config)

    if issue.state == "human-review" and Aiur.AgentCompaction.Config.should_compact_at_handoff?(compaction_config, agent_total_tokens) and
         Aiur.AgentCompaction.Orchestrator.supported_backend?("codex") do
      prior =
        case Aiur.AgentCompaction.Store.load(issue.identifier) do
          {:ok, state} ->
            state

          {:error, reason} ->
            Logger.warning("Could not read prior Codex compaction state for #{issue.identifier}; skipping compaction: #{inspect(reason)}")
            %{"thread_id" => app_session.thread_id, "status" => "unreadable"}
        end

      if prior["status"] == "unreadable" or Aiur.AgentCompaction.Orchestrator.already_attempted_for_thread?(prior, app_session.thread_id) do
        Logger.info("Codex compaction skipped for unchanged waiting session identifier=#{issue.identifier}")
        return_completed(turn_context, issue)
      else
        case Aiur.AgentCompaction.Store.save(issue.identifier, %{"thread_id" => app_session.thread_id, "status" => "pending"}) do
          :ok ->
            case Aiur.AgentCompaction.Orchestrator.trigger_compaction(
                   app_session,
                   "codex",
                   turn_context.turn_number,
                   on_status: compaction_status_callback(turn_context, app_session, issue)
                 ) do
              {:ok, :completed, state} ->
                _ = Aiur.AgentCompaction.Store.save(issue.identifier, %{"thread_id" => app_session.thread_id, "compacted_thread_id" => state.compacted_transcript_ref, "status" => "completed"})
                Logger.info("Codex compaction completed before review handoff identifier=#{issue.identifier}")

              {:error, reason} ->
                _ = Aiur.AgentCompaction.Store.save(issue.identifier, %{"thread_id" => app_session.thread_id, "status" => "failed", "reason" => inspect(reason)})
                Logger.warning("Codex compaction failed; preserving normal review handoff identifier=#{issue.identifier} reason=#{inspect(reason)}")
            end

          {:error, reason} ->
            Logger.warning("Could not persist Codex compaction pending state for #{issue.identifier}; skipping compaction: #{inspect(reason)}")
        end

        return_completed(turn_context, issue)
      end
    else
      return_completed(turn_context, issue)
    end
  rescue
    error ->
      Logger.warning("Codex compaction failed; preserving normal review handoff identifier=#{issue.identifier} reason=#{Exception.message(error)}")
      return_completed(turn_context, issue)
  end

  defp compact_for_review_handoff(turn_context, app_session, issue) do
    thread_id = Map.get(app_session, :thread_id)
    compaction_config = Aiur.AgentCompaction.Config.settings()
    agent_total_tokens = token_count_for_compaction(turn_context, issue, compaction_config)

    if issue.state == "human-review" and Aiur.AgentCompaction.Config.trigger_requested_at_handoff?(compaction_config, agent_total_tokens) and
         not Aiur.AgentCompaction.Orchestrator.supported_backend?(Map.get(app_session, :backend)) do
      if not Aiur.AgentCompaction.Orchestrator.already_attempted_for_thread?(
           Aiur.AgentCompaction.Store.load(issue.identifier) |> elem(1),
           thread_id
         ) do
        compaction_status_callback(turn_context, app_session, issue).(:unsupported, thread_id, nil)

        if is_binary(thread_id) do
          _ = Aiur.AgentCompaction.Store.save(issue.identifier, %{"thread_id" => thread_id, "status" => "unsupported"})
        end
      end
    end

    return_completed(turn_context, issue)
  rescue
    _error -> return_completed(turn_context, issue)
  end

  defp current_agent_total_tokens(%{orchestrator: orchestrator}, issue) do
    case Aiur.Orchestrator.status(orchestrator, 5_000) do
      entries when is_list(entries) ->
        case Enum.find(entries, &(Map.get(&1, :identifier) == issue.identifier)) do
          %{agent_total_tokens: tokens} when is_integer(tokens) and tokens >= 0 -> tokens
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _error -> nil
  end

  defp token_count_for_compaction(turn_context, issue, %{auto_trigger: %{enabled: true}}),
    do: current_agent_total_tokens(turn_context, issue)

  defp token_count_for_compaction(_turn_context, _issue, _config), do: nil

  defp compaction_status_callback(%{workspace: workspace, worker_host: worker_host}, app_session, issue) do
    fn status, thread_id, detail ->
      message =
        case status do
          :pending -> "Native Codex compaction pending"
          :completed -> "Native Codex compaction completed"
          :failed -> "Native Codex compaction failed: #{inspect(detail)}"
          :unsupported -> "Native compaction unsupported for this provider"
        end

      Aiur.Alerts.emit_custom("compaction.#{status}", message,
        issue: issue,
        workspace: workspace,
        worker_host: worker_host,
        reason: "Codex thread compaction #{status}",
        needs_attention: false,
        severity: if(status == :failed, do: "warning", else: "info"),
        observation_identity: Issue.tracker_identity(issue),
        observation_source: %{kind: :agent_alert, name: "compaction.#{status}"},
        observation_provenance: %{
          run_id: Aiur.Boot.run_id(),
          session_id: thread_id || Map.get(app_session, :thread_id)
        },
        occurred_at: DateTime.utc_now()
      )
    end
  end

  # #2806: the state label alone is not a licence to re-prompt. Fold this
  # turn's observable-progress witness into the run's consecutive-no-op counter
  # and stop the loop — loudly, and without mutating the ticket — once a run of
  # turns that changed nothing reaches the cap. A productive turn zeroes the
  # counter, so a long run of real work is never bounded by this path.
  defp continue_unless_noop_bound(turn_context, app_session, refreshed_issue) do
    %{
      workspace: workspace,
      worker_host: worker_host,
      opts: opts,
      turn_number: turn_number,
      max_turns: max_turns,
      prompt: prompt
    } = turn_context

    witness = TurnProgress.witness(prompt, workspace, worker_host, refreshed_issue, opts)
    {verdict, progress} = TurnProgress.observe(TurnProgress.from_opts(opts), witness)
    cap = noop_turn_cap(opts)

    if verdict == :noop and is_integer(cap) and progress.consecutive_noops >= cap do
      stop_on_noop_bound(turn_context, refreshed_issue, progress, witness, cap)
    else
      Logger.info(
        "aiur_autonomous_loop phase=recurse elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} turn=#{turn_number + 1}/#{max_turns_display(max_turns)} reason=turn_completed noop_turns=#{progress.consecutive_noops}"
      )

      Logger.info("Continuing agent run for #{Aiur.AgentRunner.issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns_display(max_turns)}")

      if verdict == :noop, do: apply_noop_backoff(refreshed_issue, progress, cap, opts)

      continue_issue_turn(
        %{
          turn_context
          | issue: refreshed_issue,
            turn_number: turn_number + 1,
            opts: Keyword.put(opts, :turn_progress, progress)
        },
        app_session
      )
    end
  end

  # The bound must leave a durable record, not a bare `Logger.info` (#2797):
  # the ticket-scoped needs-attention alert lands in the alert ledger and the
  # central `alerts.ndjson`, naming the ticket, the count, and the state label
  # that kept the loop alive. The loop then takes the SAME exit as
  # `agent.max_turns` — control returns to the orchestrator with the ticket
  # untouched, so nothing is stranded: the labels an operator (or the tracker)
  # can act on are exactly as the agent left them.
  defp stop_on_noop_bound(turn_context, refreshed_issue, progress, witness, cap) do
    %{workspace: workspace, worker_host: worker_host, turn_number: turn_number, max_turns: max_turns} =
      turn_context

    Logger.warning(
      "aiur_autonomous_loop phase=noop_bound_reached elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} turn=#{turn_number}/#{max_turns_display(max_turns)} noop_turns=#{progress.consecutive_noops} cap=#{cap}"
    )

    TurnAlerts.emit_noop_turn_bound_alert(refreshed_issue, workspace, worker_host, %{
      consecutive_noops: progress.consecutive_noops,
      cap: cap,
      turn_number: turn_number,
      unchanged: TurnProgress.unchanged_witnesses(witness)
    })

    return_completed(turn_context, refreshed_issue)
  end

  # Widen the interval before each further no-op turn so an unbounded-looking
  # spin costs tens of seconds instead of a turn every seven seconds.
  defp apply_noop_backoff(issue, progress, cap, opts) do
    backoff_ms = noop_backoff_ms(progress.consecutive_noops, opts)

    if backoff_ms > 0 do
      Logger.warning(
        "Turn changed nothing observable for #{Aiur.AgentRunner.issue_context(issue)}: consecutive no-op turns=#{progress.consecutive_noops}/#{inspect(cap)}; backing off #{backoff_ms}ms before the next continuation turn"
      )

      Process.sleep(backoff_ms)
    end

    :ok
  end

  @doc false
  @spec noop_backoff_ms(non_neg_integer(), keyword()) :: non_neg_integer()
  def noop_backoff_ms(consecutive_noops, opts \\ []) do
    case Keyword.fetch(opts, :noop_backoff_ms) do
      {:ok, override} when is_integer(override) and override >= 0 ->
        override

      _absent ->
        min(consecutive_noops * @noop_backoff_step_ms, @noop_backoff_ceiling_ms)
    end
  end

  # nil / 0 disables the bound, matching how `agent.max_turns` reads "uncapped".
  @doc false
  @spec noop_turn_cap(keyword()) :: pos_integer() | nil
  def noop_turn_cap(opts) do
    opts
    |> Keyword.get(:max_consecutive_noop_turns, Config.agent_max_consecutive_noop_turns())
    |> case do
      cap when is_integer(cap) and cap > 0 -> cap
      _disabled -> nil
    end
  end

  @doc false
  @spec return_completed(map(), Issue.t()) :: {:completed, Issue.t()}
  def return_completed(turn_context, %Issue{} = issue) when is_map(turn_context),
    do: {:completed, issue}

  defp wait_for_resume(turn_context, app_session, message_handler) do
    %{
      issue: issue,
      orchestrator: orchestrator,
      codex_update_recipient: codex_update_recipient,
      opts: opts
    } = turn_context

    with :ok <-
           QueueDrain.wait_for_operator_message(
             app_session,
             issue,
             message_handler,
             orchestrator,
             codex_update_recipient,
             opts
           ) do
      continue_after_resume(turn_context, app_session)
    end
  end

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
              opts: Keyword.put(turn_context.opts, :turn_progress, TurnProgress.empty())
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

  @doc false
  @spec continue_with_issue?(Issue.t(), fun()) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher)
      when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        # A ticket carrying the `agent:paused` override must stop receiving
        # automatic continuation turns even though its underlying state label
        # (e.g. `agent:todo`) remains in `tracker.active_states`. The paused
        # marker is what parks the ticket; recursing on the state label alone
        # fired turn after turn on a paused ticket until `agent.max_turns` was
        # reached (#1686). Mirror the pause check the resume path already
        # applies in `Aiur.Orchestrator.AutoResume.resumable?/2`.
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

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp coding_agent_run_turn(opts), do: Keyword.get(opts, :run_turn, &CodingAgent.run_turn/4)
end
