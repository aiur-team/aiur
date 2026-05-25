defmodule Aiur.AgentRunner do
  @moduledoc """
  Executes a single issue in its workspace with the configured coding agent.
  """

  require Logger

  alias Aiur.{
    AgentEventLog,
    AgentEvents,
    AgentPubSub,
    Alerts,
    CodingAgent,
    Config,
    Issue,
    IssueLog,
    PromptBuilder,
    Tracker,
    Workspace
  }

  alias Aiur.Codex.DynamicTool
  alias Aiur.Events.{Publisher, SubscriptionStore}
  alias Aiur.GitHub.IssueDependencies
  alias Aiur.Opencode.{ApiClient, Protocol, SessionWriterRegistry}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    # Make sure a per-issue file writer is running so this session's
    # transcript and alert events land in <repo>.<issue>.log alongside any
    # earlier session's output.
    maybe_attach_issue_log(issue)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue, workspace, worker_host, turn_id \\ nil) do
    fn message ->
      message = CodingAgent.normalize_event(message)
      AgentEventLog.write(workspace, worker_host, message)
      maybe_broadcast_transcript(issue, message, turn_id)
      maybe_broadcast_turn_event(issue, message, turn_id)
      send_codex_update(recipient, issue, message)
    end
  end

  defp maybe_broadcast_transcript(%Issue{identifier: identifier}, message, turn_id)
       when is_binary(identifier) do
    case transcript_event_from(message, turn_id) do
      {:ok, event} -> AgentPubSub.broadcast_transcript(identifier, event)
      :skip -> :ok
    end
  end

  defp maybe_broadcast_transcript(_issue, _message, _turn_id), do: :ok

  defp maybe_broadcast_turn_event(%Issue{identifier: identifier}, message, turn_id)
       when is_binary(identifier) and is_binary(turn_id) do
    case event_kind(message) do
      kind when kind in ["turn_completed", "turn_failed", "turn_cancelled", "turn_input_required"] ->
        payload = %{turn_id: turn_id, payload: message}
        AgentPubSub.broadcast_turn_event(identifier, String.to_existing_atom(kind), payload)

      _ ->
        :ok
    end
  end

  defp maybe_broadcast_turn_event(_issue, _message, _turn_id), do: :ok

  # Dispatch to the active backend's transcript extractor (codex or
  # Claude). Falls back to the universal legacy event-kind mapping for
  # non-notification shapes (older agent_message / task_finished events).
  defp transcript_event_from(message, turn_id) when is_map(message) do
    case CodingAgent.transcript_module().extract(message, turn_id) do
      {:ok, event} -> {:ok, event}
      :skip -> legacy_transcript_event(message, turn_id)
    end
  end

  defp legacy_transcript_event(message, turn_id) do
    role = role_for_event(message)
    body = body_for_event(message)

    cond do
      is_nil(role) -> :skip
      is_nil(body) -> :skip
      body == "" -> :skip
      true -> {:ok, AgentEvents.transcript_event(role, body, timestamp: timestamp_for(message), turn_id: turn_id)}
    end
  end

  defp role_for_event(message) do
    case event_kind(message) do
      kind when kind in ["agent_message", "assistant_message", "task_finished", "task_complete"] ->
        :assistant

      kind when kind in ["user_message", "operator_message"] ->
        :user

      _ ->
        nil
    end
  end

  defp event_kind(message) do
    case get(message, :event) do
      nil -> nil
      atom when is_atom(atom) -> Atom.to_string(atom)
      other -> to_string(other)
    end
  end

  defp body_for_event(message) do
    get(message, :last_message) ||
      get(message, :body) ||
      nil
  end

  # Look up `key` in `map` using both atom and binary forms so we tolerate
  # either shape (`%{event: "..."}` or `%{"event" => "..."}`) — codex events
  # arrive as string-keyed JSON, while internal messages stay atom-keyed.
  defp get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get(_map, _key), do: nil

  defp timestamp_for(message) do
    case Map.get(message, :timestamp) || Map.get(message, "timestamp") do
      %DateTime{} = ts -> ts
      _ -> DateTime.utc_now()
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    orchestrator = Keyword.get(opts, :orchestrator, Aiur.Orchestrator)

    with {:ok, session} <- CodingAgent.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          orchestrator,
          worker_host,
          1,
          max_turns
        )
      after
        CodingAgent.stop_session(session)
      end
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp do_run_codex_turns(
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

    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    message_handler = codex_message_handler(codex_update_recipient, issue, workspace, worker_host)
    safe_checkpoint_handler = safe_checkpoint_handler(issue, orchestrator)

    send_control_state(codex_update_recipient, issue, :working)
    aiur_turn_id = open_aiur_turn_streams(issue)

    result =
      CodingAgent.run_turn(
        app_session,
        prompt,
        issue,
        on_message: message_handler,
        on_safe_checkpoint: safe_checkpoint_handler,
        tool_executor: tool_executor(issue, workspace, worker_host)
      )

    close_aiur_turn_streams(issue, aiur_turn_id, turn_done_reason(result))

    case result do
      {:ok, turn_session} ->
        :ok = Aiur.Orchestrator.consume_delivered_queue_items(orchestrator, issue.identifier)

        with :ok <-
               drain_operator_messages(
                 app_session,
                 issue,
                 message_handler,
                 orchestrator,
                 codex_update_recipient
               ) do
          finalize_turn_completion(turn_context, app_session, turn_session)
        end

      {:paused, pause_payload} ->
        Logger.info("Paused agent run for #{issue_context(issue)} session_id=#{pause_payload[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

        :ok = Aiur.Orchestrator.restore_delivered_queue_items(orchestrator, issue.identifier)
        write_pause_log(workspace, worker_host)
        send_control_state(codex_update_recipient, issue, :paused)
        wait_for_resume(turn_context, app_session, message_handler)

      {:error, reason} ->
        maybe_emit_more_tokens_alert(issue, workspace, worker_host, reason)
        :ok = Aiur.Orchestrator.fail_delivered_queue_items(orchestrator, issue.identifier, reason)
        {:error, reason}
    end
  end

  defp turn_done_reason({:ok, _session}), do: :done
  defp turn_done_reason({:paused, _payload}), do: :input_required
  defp turn_done_reason({:error, reason}), do: {:failed, reason}
  defp turn_done_reason(_), do: :done

  defp finalize_turn_completion(turn_context, app_session, turn_session) do
    %{
      workspace: workspace,
      issue: issue,
      issue_state_fetcher: issue_state_fetcher,
      turn_number: turn_number,
      max_turns: max_turns
    } = turn_context

    Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

    case continue_with_issue?(issue, issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        Logger.info("aiur_autonomous_loop phase=recurse elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} turn=#{turn_number + 1}/#{max_turns} reason=turn_completed")

        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

        continue_issue_turn(%{turn_context | issue: refreshed_issue, turn_number: turn_number + 1}, app_session)

      {:continue, refreshed_issue} ->
        Logger.info("aiur_autonomous_loop phase=max_turns_reached elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} turn=#{turn_number}/#{max_turns}")

        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

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
           wait_for_operator_message(
             app_session,
             issue,
             message_handler,
             orchestrator,
             codex_update_recipient
           ) do
      case continue_with_issue?(issue, turn_context.issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_context.turn_number < turn_context.max_turns ->
          Logger.info(
            "aiur_autonomous_loop phase=recurse elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} turn=#{turn_context.turn_number + 1}/#{turn_context.max_turns} reason=resume"
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
    do_run_codex_turns(
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

  defp drain_operator_messages(app_session, issue, message_handler, orchestrator, codex_update_recipient) do
    receive do
      {:pause_agent, request_id} when is_integer(request_id) ->
        Logger.info("Agent already paused for #{issue_context(issue)} request_id=#{request_id}")
        send_control_state(codex_update_recipient, issue, :paused)
        wait_for_operator_message(app_session, issue, message_handler, orchestrator, codex_update_recipient)
    after
      0 -> drain_queued_operator_messages(app_session, issue, message_handler, orchestrator, codex_update_recipient)
    end
  end

  # Paused state. Wait for an explicit wake signal — a new
  # `:agent_queue_updated` broadcast from the orchestrator, or a
  # `:resume_agent` control message — before touching the operator
  # queue. Eagerly claiming on entry was a foot-gun: when the operator
  # paused mid-turn, `restore_delivered_queue_items/2` put the in-flight
  # item back in the queue, and the very next entry to this function
  # would re-claim and re-resume in a tight loop that no amount of
  # repeat pause-key presses could escape.
  defp wait_for_operator_message(app_session, issue, message_handler, orchestrator, codex_update_recipient) do
    receive do
      {:agent_queue_updated, issue_identifier, _item_id} when issue_identifier == issue.identifier ->
        try_claim_after_queue_update(app_session, issue, message_handler, orchestrator, codex_update_recipient)

      {:agent_queue_updated, issue_identifier, _item_id, _interrupt_requested}
      when issue_identifier == issue.identifier ->
        try_claim_after_queue_update(app_session, issue, message_handler, orchestrator, codex_update_recipient)

      {:pause_agent, request_id} when is_integer(request_id) ->
        Logger.info("Agent already paused for #{issue_context(issue)} request_id=#{request_id}")
        send_control_state(codex_update_recipient, issue, :paused)
        wait_for_operator_message(app_session, issue, message_handler, orchestrator, codex_update_recipient)

      {:resume_agent, request_id} when is_integer(request_id) ->
        Logger.info("Resuming paused agent for #{issue_context(issue)} request_id=#{request_id}")
        send_control_state(codex_update_recipient, issue, :working)
        # An explicit resume drains the operator queue so restored items
        # land in the same turn instead of being deferred until the next
        # checkpoint of an initial-prompt turn.
        claim_and_run_or_continue(app_session, issue, message_handler, orchestrator, codex_update_recipient)
    end
  end

  defp try_claim_after_queue_update(app_session, issue, message_handler, orchestrator, codex_update_recipient) do
    case claim_next_operator_item(orchestrator, issue.identifier) do
      {:ok, item} ->
        Logger.info("Resuming paused agent for #{issue_context(issue)} request_id=#{item.id}")
        send_control_state(codex_update_recipient, issue, :working)
        run_operator_turn(app_session, issue, item, message_handler, orchestrator, codex_update_recipient)

      :empty ->
        wait_for_operator_message(app_session, issue, message_handler, orchestrator, codex_update_recipient)
    end
  end

  defp claim_and_run_or_continue(app_session, issue, message_handler, orchestrator, codex_update_recipient) do
    case claim_next_operator_item(orchestrator, issue.identifier) do
      {:ok, item} ->
        run_operator_turn(app_session, issue, item, message_handler, orchestrator, codex_update_recipient)

      :empty ->
        :ok
    end
  end

  defp drain_queued_operator_messages(app_session, issue, message_handler, orchestrator, codex_update_recipient) do
    case claim_next_queue_item(orchestrator, issue.identifier) do
      {:ok, item} ->
        Logger.info("Delivering queued item to #{issue_context(issue)} request_id=#{item.id} category=#{item.category}")
        run_queue_item_turn(app_session, issue, item, message_handler, orchestrator, codex_update_recipient)

      :empty ->
        :ok
    end
  end

  defp claim_next_queue_item(orchestrator, issue_identifier) when is_binary(issue_identifier) do
    case Aiur.Orchestrator.claim_next_queue_item(orchestrator, issue_identifier) do
      {:ok, item} -> {:ok, item}
      :empty -> :empty
      {:error, _reason} -> :empty
    end
  end

  defp claim_next_operator_item(orchestrator, issue_identifier) when is_binary(issue_identifier) do
    case Aiur.Orchestrator.claim_next_operator_queue_item(orchestrator, issue_identifier) do
      {:ok, item} -> {:ok, item}
      :empty -> :empty
      {:error, _reason} -> :empty
    end
  end

  defp run_operator_turn(app_session, issue, item, message_handler, orchestrator, codex_update_recipient) do
    run_queue_item_turn(app_session, issue, item, message_handler, orchestrator, codex_update_recipient)
  end

  defp run_queue_item_turn(app_session, issue, item, _message_handler, orchestrator, codex_update_recipient) do
    text = queue_item_text(item)
    turn_id = queue_item_turn_id(item)
    workspace = session_workspace(app_session)
    worker_host = session_worker_host(app_session)
    message_handler = codex_message_handler(codex_update_recipient, issue, workspace, worker_host, turn_id)
    safe_checkpoint_handler = safe_checkpoint_handler(issue, orchestrator)

    send_control_state(codex_update_recipient, issue, :working)
    aiur_turn_id = open_aiur_turn_streams(issue)

    result =
      CodingAgent.run_turn(
        app_session,
        text,
        issue,
        on_message: message_handler,
        on_safe_checkpoint: safe_checkpoint_handler,
        tool_executor: tool_executor(issue, session_workspace(app_session), session_worker_host(app_session))
      )

    close_aiur_turn_streams(issue, aiur_turn_id, turn_done_reason(result))

    case result do
      {:ok, _turn_session} ->
        :ok = Aiur.Orchestrator.consume_delivered_queue_items(orchestrator, issue.identifier)

        if is_binary(turn_id) do
          AgentPubSub.broadcast_turn_event(issue.identifier, :turn_completed, %{turn_id: turn_id})
        end

        drain_operator_messages(app_session, issue, message_handler, orchestrator, codex_update_recipient)

      {:paused, _payload} ->
        :ok = Aiur.Orchestrator.restore_delivered_queue_items(orchestrator, issue.identifier)
        write_pause_log(session_workspace(app_session), session_worker_host(app_session))
        send_control_state(codex_update_recipient, issue, :paused)
        wait_for_operator_message(app_session, issue, message_handler, orchestrator, codex_update_recipient)

      {:error, reason} = error ->
        :ok = Aiur.Orchestrator.fail_delivered_queue_items(orchestrator, issue.identifier, reason)

        if is_binary(turn_id) do
          AgentPubSub.broadcast_turn_event(issue.identifier, :turn_failed, %{turn_id: turn_id, reason: reason})
        end

        error
    end
  end

  defp queue_item_turn_id(%{turn_id: turn_id}) when is_binary(turn_id), do: turn_id
  defp queue_item_turn_id(%{body: %{turn_id: turn_id}}) when is_binary(turn_id), do: turn_id
  defp queue_item_turn_id(_item), do: nil

  defp queue_item_text(%{category: :operator_message, body: %{text: text}}), do: text

  defp queue_item_text(%{
         category: :coordination_event,
         event_type: :events_digest,
         target_issue_identifier: identifier,
         body: %{events: events}
       })
       when is_list(events) do
    rendered_events = Enum.map_join(events, "\n", &render_event_line/1)

    for event <- events do
      topic = Map.get(event, :topic) || Map.get(event, "topic") || "(unknown)"
      id = Map.get(event, :id) || Map.get(event, "id")
      Aiur.Events.DebugLog.broadcast(:read, topic, id: id, identifier: identifier)
    end

    "<aiur:events>\n" <> rendered_events <> "\n</aiur:events>"
  end

  defp queue_item_text(%{
         category: :coordination_event,
         event_type: :events_digest,
         body: %{events: events}
       })
       when is_list(events) do
    rendered_events = Enum.map_join(events, "\n", &render_event_line/1)
    "<aiur:events>\n" <> rendered_events <> "\n</aiur:events>"
  end

  defp queue_item_text(%{category: :coordination_event, event_type: event_type, body: body}) do
    summary = Map.get(body, :summary) || Map.get(body, "summary") || inspect(body)

    """
    Coordination event: #{event_type}

    #{summary}
    """
    |> String.trim()
  end

  defp queue_item_text(item), do: inspect(item)

  defp render_event_line(event) when is_map(event) do
    topic = Map.get(event, :topic) || Map.get(event, "topic") || "(unknown)"
    id = Map.get(event, :id) || Map.get(event, "id")

    summary =
      cond do
        msg = Map.get(event, "message") || Map.get(event, :message) -> msg
        msg = Map.get(event, "summary") || Map.get(event, :summary) -> msg
        true -> ""
      end

    "[id=#{id}] #{topic}#{if summary != "", do: ": " <> summary, else: ""}"
  end

  defp render_event_line(other), do: inspect(other)

  defp send_control_state(recipient, %Issue{id: issue_id}, status)
       when is_pid(recipient) and is_binary(issue_id) and status in [:paused, :working] do
    send(recipient, {:worker_control_state, issue_id, status})
    :ok
  end

  defp send_control_state(_recipient, _issue, _status), do: :ok

  # Bridge-as-LLM trigger: at the start of each codex turn, fan a
  # `__aiur_turn__:<id>` marker out to every opencode-serve that has a
  # SessionWriter attached for this identifier. opencode treats the
  # marker as a synthetic user message and immediately opens a
  # chat-completion request to our bridge, which holds it open and
  # streams the codex turn's events as SSE deltas
  # (see Aiur.Opencode.ChatCompletions.stream_codex_turn/3).
  # No SessionWriter attached = no opencode pane open = no-op, agent
  # keeps running (manual override preserved).
  defp open_aiur_turn_streams(%Issue{identifier: identifier}) when is_binary(identifier) do
    aiur_turn_id = "t" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)

    for %{session_id: session_id, base_url: base_url} <-
          SessionWriterRegistry.attached(identifier) do
      payload = %{
        parts: [Protocol.text_part_data("__aiur_turn__:" <> aiur_turn_id, synthetic: true)]
      }

      case ApiClient.post_message(base_url, session_id, payload) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.debug("aiur_turn_marker post_failed identifier=#{identifier} base_url=#{base_url} reason=#{inspect(reason)}")
      end
    end

    aiur_turn_id
  end

  defp open_aiur_turn_streams(_issue), do: nil

  # Match the close to the marker post — the bridge SSE for this
  # aiur_turn_id closes on the matching `:aiur_turn_done` broadcast.
  # `nil` from open_aiur_turn_streams/1 means no marker fired (no
  # SessionWriter attached or issue had no identifier); no close
  # broadcast needed.
  defp close_aiur_turn_streams(%Issue{identifier: identifier}, aiur_turn_id, reason)
       when is_binary(identifier) and is_binary(aiur_turn_id) do
    AgentPubSub.broadcast_aiur_turn_done(identifier, aiur_turn_id, reason)
    :ok
  end

  defp close_aiur_turn_streams(_issue, _aiur_turn_id, _reason), do: :ok

  defp safe_checkpoint_handler(issue, orchestrator) do
    fn checkpoint ->
      case claim_next_checkpoint_queue_item(orchestrator, issue.identifier) do
        {:ok, item} ->
          safe_checkpoint_delivery(issue, orchestrator, item, checkpoint)

        :empty ->
          :noop
      end
    end
  end

  defp claim_next_checkpoint_queue_item(orchestrator, issue_identifier) when is_binary(issue_identifier) do
    case Aiur.Orchestrator.claim_next_checkpoint_queue_item(orchestrator, issue_identifier) do
      {:ok, item} -> {:ok, item}
      :empty -> :empty
      {:error, _reason} -> :empty
    end
  end

  defp safe_checkpoint_delivery(issue, orchestrator, item, checkpoint) do
    Logger.info("Queueing operator message into active turn for #{issue_context(issue)} request_id=#{item.id} checkpoint=#{inspect(checkpoint)}")

    {:deliver_text, queue_item_text(item), fn _payload -> :ok end,
     fn reason ->
       handle_checkpoint_delivery_failure(orchestrator, item.id, reason)
     end}
  end

  defp handle_checkpoint_delivery_failure(orchestrator, item_id, {:turn_interrupted, _payload}) do
    Aiur.Orchestrator.restore_queue_item_pending(orchestrator, item_id)
  end

  defp handle_checkpoint_delivery_failure(orchestrator, item_id, {:turn_cancelled, _payload}) do
    Aiur.Orchestrator.restore_queue_item_pending(orchestrator, item_id)
  end

  defp handle_checkpoint_delivery_failure(orchestrator, item_id, reason) do
    Aiur.Orchestrator.mark_queue_item_failed(orchestrator, item_id, reason)
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous turn completed normally, but the issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
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

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp maybe_attach_issue_log(%Issue{identifier: identifier}) when is_binary(identifier),
    do: IssueLog.attach(identifier)

  defp maybe_attach_issue_log(%{identifier: identifier}) when is_binary(identifier),
    do: IssueLog.attach(identifier)

  defp maybe_attach_issue_log(_), do: :ok

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp write_pause_log(workspace, worker_host) do
    AgentEventLog.write(workspace, worker_host, %{
      event: :worker_paused,
      timestamp: DateTime.utc_now(),
      last_message: "Agent paused by operator."
    })
  end

  defp session_workspace(%{workspace: workspace}) when is_binary(workspace), do: workspace
  defp session_workspace(_session), do: nil

  defp session_worker_host(%{worker_host: worker_host}), do: worker_host
  defp session_worker_host(_session), do: nil

  defp tool_executor(issue, workspace, worker_host) do
    fn tool, arguments ->
      DynamicTool.execute(
        tool,
        arguments,
        alert_emitter: fn name, message ->
          # Agent-emitted alerts are always per-ticket — namespace under
          # `ticket.<id>.agent.<name>` so subscribers can bind by ticket
          # (and so the alert log lines a single ticket together).
          # Names that already start with `ticket.` or `system.` pass
          # through unchanged so orchestrator-side callsites (which
          # pre-build the full topic) aren't double-prefixed.
          topic = prefix_with_ticket_namespace(name, issue)

          Alerts.emit_custom(topic, message,
            issue: issue,
            workspace: workspace,
            worker_host: worker_host
          )
        end,
        event_publisher: fn name, message, payload ->
          emit_agent_event(issue, name, message, payload)
        end,
        subscriber: fn pattern -> subscribe_for_issue(issue, pattern) end,
        unsubscriber: fn pattern -> unsubscribe_for_issue(issue, pattern) end,
        blocker_declarer: fn blocker_number ->
          declare_blocker_for_issue(issue, blocker_number)
        end,
        unblocker: fn blocker_number ->
          unblock_for_issue(issue, blocker_number)
        end
      )
    end
  end

  defp prefix_with_ticket_namespace(name, issue) when is_binary(name) do
    cond do
      String.starts_with?(name, "ticket.") ->
        name

      String.starts_with?(name, "system.") ->
        name

      true ->
        case issue_identifier(issue) do
          id when is_binary(id) and id != "" -> "ticket.#{id}.agent.#{name}"
          _ -> name
        end
    end
  end

  defp prefix_with_ticket_namespace(name, _issue), do: name

  defp declare_blocker_for_issue(issue, blocker_number) do
    case issue_number_of(issue) do
      nil -> {:error, :no_issue_number}
      current -> IssueDependencies.declare(current, blocker_number)
    end
  end

  defp unblock_for_issue(issue, blocker_number) do
    case issue_number_of(issue) do
      nil -> {:error, :no_issue_number}
      current -> IssueDependencies.unblock(current, blocker_number)
    end
  end

  defp issue_number_of(issue) do
    case Map.get(issue, :number) || Map.get(issue, :identifier) do
      n when is_integer(n) -> n
      n when is_binary(n) -> n
      _ -> nil
    end
  end

  defp subscribe_for_issue(issue, pattern) do
    case issue_identifier(issue) do
      nil ->
        {:error, :no_issue_identifier}

      id ->
        :ok = SubscriptionStore.attach(id)
        SubscriptionStore.add_subscription(id, pattern, "manual:agent")
    end
  end

  defp unsubscribe_for_issue(issue, pattern) do
    case issue_identifier(issue) do
      nil -> {:error, :no_issue_identifier}
      id -> SubscriptionStore.remove_subscription(id, pattern)
    end
  end

  defp issue_identifier(issue) do
    cond do
      is_binary(Map.get(issue, :id)) -> issue.id
      is_binary(Map.get(issue, :identifier)) -> issue.identifier
      true -> nil
    end
  end

  defp emit_agent_event(issue, name, message, payload) do
    identifier = issue_identifier(issue)

    topic =
      case identifier do
        nil -> "agent.#{name}"
        id -> "ticket.#{id}.agent.#{name}"
      end

    event_payload =
      payload
      |> Map.put("message", message)
      |> Map.put("name", name)
      |> Map.put("issue", identifier)

    case Publisher.publish(topic, event_payload) do
      {:ok, id, _subscribers} -> {:ok, %{"id" => id, "topic" => topic}}
      :filtered -> {:error, :event_filtered}
      :deduped -> {:error, :event_deduped}
    end
  end

  defp maybe_emit_more_tokens_alert(issue, workspace, worker_host, reason) do
    if more_tokens_reason?(reason) do
      Alerts.emit_system(
        "ticket.#{issue.identifier}.agent.error.tokens_exhausted",
        issue: issue,
        workspace: workspace,
        worker_host: worker_host
      )
    end

    :ok
  end

  defp more_tokens_reason?(reason) do
    reason
    |> inspect()
    |> String.downcase()
    |> String.contains?([
      "rate limit exhausted",
      "token budget",
      "context length",
      "maximum context",
      "max tokens",
      "too many tokens"
    ])
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
