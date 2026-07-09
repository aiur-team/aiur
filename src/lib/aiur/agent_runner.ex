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
    Tracker,
    Workspace
  }

  alias Aiur.AgentRunner.{BootstrapDigest, CommentContext, EventsDigest, QueueDrain}
  alias Aiur.AgentRunner.{SessionLifecycle, SessionResume, TurnLoop, TurnPrompt}
  alias Aiur.Codex.DynamicTool
  alias Aiur.Events.{Publisher, SubscriptionStore}
  alias Aiur.GitHub.IssueDependencies
  alias Aiur.Opencode.{ActiveTurns, ApiClient, SessionWriterRegistry, TurnMarkers}
  alias Aiur.Protocol.MapAccess

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
        if transient_run_error?(reason) do
          Logger.warning("Agent run interrupted by transient condition for #{issue_context(issue)}: #{inspect(reason)}; exiting cleanly to re-dispatch with a fresh session")
          :ok
        else
          Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
          raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
        end
    end
  end

  # A mid-turn REPL pane death (`:repl_gone`) is a transient, recoverable
  # condition — the cloud-mediated remote-control pane dropped (flaky link or
  # operator-closed pane), not a broken agent. Raising on it would exit the
  # Task abnormally, booking a *failure* retry that counts against
  # max_retry_attempts; a few disconnects would then strand the issue. Exiting
  # cleanly instead lets the orchestrator schedule a cheap continuation
  # re-dispatch with a fresh pane (the thrash breaker still guards against a
  # tight respawn loop).
  #
  # An undelivered prompt (`:prompt_not_delivered`) is recoverable the same
  # way: a single paste that the pane could not confirm (RC input contention,
  # a slow render) must not tear down an otherwise-healthy agent and crash the
  # run. Re-dispatch with a fresh pane instead of hard-failing.
  @doc false
  @spec transient_run_error?(term()) :: boolean()
  def transient_run_error?(:repl_gone), do: true
  def transient_run_error?(:prompt_not_delivered), do: true
  def transient_run_error?(_reason), do: false

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        run_worker_attempt(workspace, issue, codex_update_recipient, opts, worker_host)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_worker_attempt(workspace, issue, codex_update_recipient, opts, worker_host) do
    case run_worker_attempt_once(workspace, issue, codex_update_recipient, opts, worker_host) do
      :resume_after_before_run_pause ->
        run_worker_attempt(workspace, issue, codex_update_recipient, opts, worker_host)

      result ->
        result
    end
  end

  defp run_worker_attempt_once(workspace, issue, codex_update_recipient, opts, worker_host) do
    result =
      try do
        case Workspace.run_before_run_hook(workspace, issue, worker_host) do
          :ok ->
            :ok = BootstrapDigest.maybe_attach_universal_subscriptions(issue)
            :ok = BootstrapDigest.maybe_enqueue_bootstrap_digest(issue)
            SessionLifecycle.run_session(workspace, issue, codex_update_recipient, opts, worker_host)

          {:error, {:workspace_hook_failed, "before_run", status, output} = reason} ->
            {:before_run_failed, status, output, reason}

          {:error, reason} ->
            {:error, reason}
        end
      after
        Workspace.run_after_run_hook(workspace, issue, worker_host)
      end

    case result do
      {:before_run_failed, status, output, reason} ->
        pause_for_before_run_failure(workspace, issue, codex_update_recipient, worker_host, status, output, reason)

      other ->
        other
    end
  end

  defp pause_for_before_run_failure(workspace, issue, codex_update_recipient, worker_host, status, output, reason) do
    Logger.warning("Pausing agent for #{issue_context(issue)} after before_run hook failed status=#{inspect(status)} output=#{inspect(trim_hook_output(output))}")

    write_pause_log(workspace, worker_host, "before_run hook failed; agent paused pending operator resume.")
    send_control_state(codex_update_recipient, issue, :paused)
    wait_for_before_run_resume(issue, codex_update_recipient, reason)
  end

  @doc false
  @spec current_comment_context_events_for_test(Issue.t(), map()) :: [map()]
  def current_comment_context_events_for_test(issue, fetchers) when is_map(fetchers) do
    CommentContext.events(issue, fetchers)
  end

  @doc false
  @spec codex_message_handler(
          pid() | nil,
          Issue.t(),
          Path.t() | nil,
          worker_host(),
          String.t(),
          String.t() | nil
        ) :: fun()
  def codex_message_handler(recipient, issue, workspace, worker_host, backend, turn_id \\ nil) do
    fn message ->
      message = CodingAgent.normalize_event(message, backend)
      AgentEventLog.write(workspace, worker_host, message)
      maybe_broadcast_transcript(issue, message, backend, turn_id)
      maybe_broadcast_turn_event(issue, message, turn_id)
      send_codex_update(recipient, issue, message)
    end
  end

  defp maybe_broadcast_transcript(%Issue{identifier: identifier}, message, backend, turn_id)
       when is_binary(identifier) do
    case transcript_event_from(message, backend, turn_id) do
      {:ok, event} -> AgentPubSub.broadcast_transcript(identifier, event)
      :skip -> :ok
    end
  end

  defp maybe_broadcast_transcript(_issue, _message, _backend, _turn_id), do: :ok

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
  defp transcript_event_from(message, backend, turn_id) when is_map(message) do
    case CodingAgent.transcript_module(backend).extract(message, turn_id) do
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
  defp get(map, key), do: MapAccess.get(map, key)

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

  @doc false
  @spec resume_thread_id(String.t(), worker_host(), {:ok, map()} | :none) :: String.t() | nil
  def resume_thread_id(backend, worker_host, handle), do: SessionResume.resume_thread_id(backend, worker_host, handle)

  @doc false
  @spec session_resumed?(map()) :: boolean()
  def session_resumed?(session), do: SessionResume.session_resumed?(session)

  @doc false
  @spec turn_handle_attrs(map(), map()) :: {:ok, map()} | :skip
  def turn_handle_attrs(a, b), do: SessionResume.turn_handle_attrs(a, b)

  @doc false
  @spec session_handle_to_save(map(), worker_host()) :: {:ok, map()} | :skip
  def session_handle_to_save(s, w), do: SessionResume.session_handle_to_save(s, w)

  @doc false
  @spec persist_handle_best_effort(String.t(), map(), keyword()) :: :ok
  def persist_handle_best_effort(id, attrs, opts \\ []), do: SessionResume.persist_handle_best_effort(id, attrs, opts)

  @doc false
  @spec should_display_tail?(String.t() | nil, boolean(), String.t() | nil) :: boolean()
  def should_display_tail?(b, rc?, id), do: SessionLifecycle.should_display_tail?(b, rc?, id)

  @doc false
  @spec remote_session_backend(String.t(), boolean()) :: String.t()
  def remote_session_backend(b, rc?), do: SessionLifecycle.remote_session_backend(b, rc?)

  @doc false
  @spec maybe_trust_remote_control_workspace(
          Path.t(),
          boolean(),
          worker_host(),
          (Path.t() -> :ok | {:error, term()})
        ) :: :ok
  def maybe_trust_remote_control_workspace(ws, rc?, wh, fun),
    do: SessionLifecycle.maybe_trust_remote_control_workspace(ws, rc?, wh, fun)

  @doc false
  @spec rc_session_name(Issue.t(), String.t() | nil) :: String.t()
  def rc_session_name(issue, repo \\ Tracker.project_identity()), do: SessionLifecycle.rc_session_name(issue, repo)

  @doc false
  @spec start_agent_session(
          Path.t(),
          keyword(),
          (Path.t(), keyword() -> {:ok, map()} | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def start_agent_session(ws, opts, start_fun \\ &CodingAgent.start_session/2),
    do: SessionLifecycle.start_agent_session(ws, opts, start_fun)

  # Delivered-queue bookkeeping RPCs return `{:error, :unavailable}` (or
  # `:timeout`) when the orchestrator is momentarily overloaded — e.g. when an
  # exhausted Codex account floods `account/rateLimits/updated` events. That is
  # best-effort housekeeping: a hard `:ok =` match there turned a transient
  # overload into a `MatchError` that crashed the agent Task and booked a retry,
  # stalling the ticket (#768). Worse, the crash fired in the `{:ok, _}` branch
  # before a later turn could reach the usage-limit `{:paused, _}` pause — so
  # logging and continuing here also lets that existing pause path run.
  @doc false
  @spec best_effort_queue_bookkeeping(:ok | {:error, term()}, atom(), Issue.t()) :: :ok
  def best_effort_queue_bookkeeping(:ok, _op, _issue), do: :ok

  def best_effort_queue_bookkeeping({:error, reason}, op, issue) do
    Logger.warning("Orchestrator #{op}_delivered_queue_items unavailable for #{issue_context(issue)}: #{inspect(reason)}; continuing without crashing the agent")

    :ok
  end

  @doc false
  @spec turn_done_reason(term()) :: :done | :input_required | {:failed, term()}
  def turn_done_reason(result), do: TurnLoop.turn_done_reason(result)

  defp wait_for_before_run_resume(issue, codex_update_recipient, reason) do
    receive do
      {:pause_agent, request_id} when is_integer(request_id) ->
        Logger.info("Agent already paused before run for #{issue_context(issue)} request_id=#{request_id}")
        send_control_state(codex_update_recipient, issue, :paused)
        wait_for_before_run_resume(issue, codex_update_recipient, reason)

      {:resume_agent, request_id} when is_integer(request_id) ->
        Logger.info("Resuming agent after before_run failure for #{issue_context(issue)} request_id=#{request_id}")
        send_control_state(codex_update_recipient, issue, :working)
        :resume_after_before_run_pause
    end
  end

  @doc false
  @spec claim_after_queue_update_for_test(GenServer.server(), String.t(), boolean()) ::
          {:ok, map()} | :empty | :ignored
  def claim_after_queue_update_for_test(orchestrator, issue_identifier, deliver_now?)
      when is_binary(issue_identifier) and is_boolean(deliver_now?) do
    QueueDrain.claim_after_queue_update(orchestrator, issue_identifier, deliver_now?)
  end

  @doc false
  @spec render_events_digest_for_test([map()], String.t()) :: String.t()
  def render_events_digest_for_test(events, identifier) when is_list(events) and is_binary(identifier) do
    EventsDigest.render(events, identifier)
  end

  @doc false
  @spec send_control_state(pid() | nil, Issue.t(), :paused | :working | term()) :: :ok
  def send_control_state(recipient, %Issue{id: issue_id}, status)
      when is_pid(recipient) and is_binary(issue_id) and status in [:paused, :working] do
    send(recipient, {:worker_control_state, issue_id, status})
    :ok
  end

  def send_control_state(_recipient, _issue, _status), do: :ok

  # Bridge-as-LLM trigger: at the start of each codex turn, fan a
  # `__aiur_turn__:<id>` marker out to every opencode-serve that has a
  # SessionWriter attached for this identifier. opencode treats the
  # marker as a synthetic user message and immediately opens a
  # chat-completion request to our bridge, which holds it open and
  # streams the codex turn's events as SSE deltas
  # (see Aiur.Opencode.ChatCompletions.stream_codex_turn/3).
  # No SessionWriter attached = no opencode pane open = no-op, agent
  # keeps running (manual override preserved).
  @doc false
  @spec open_aiur_turn_streams(Issue.t()) :: String.t() | nil
  def open_aiur_turn_streams(%Issue{identifier: identifier}) when is_binary(identifier) do
    aiur_turn_id = "t" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
    # Register BEFORE posting so the bridge always observes :active when
    # it handles the resulting chat-completion. Stale markers replayed
    # by opencode-serve from a previous boot will be absent from the
    # table and the bridge will close them as phantom.
    :ok = ActiveTurns.put(identifier, aiur_turn_id)

    writers = SessionWriterRegistry.attached(identifier)
    :ok = post_aiur_turn_markers(identifier, aiur_turn_id, writers)

    aiur_turn_id
  end

  def open_aiur_turn_streams(_issue), do: nil

  @doc """
  Fire `__aiur_turn__:<id>` marker posts to every attached opencode-serve.
  Delegates to `Aiur.Opencode.TurnMarkers.post_all/4`, which also serves the
  bridge's continuation markers (segmented turn streams).
  """
  @spec post_aiur_turn_markers(
          String.t(),
          String.t(),
          [%{session_id: String.t(), base_url: String.t()}],
          (String.t(), String.t(), map() -> {:ok, term()} | {:error, term()})
        ) :: :ok
  def post_aiur_turn_markers(identifier, aiur_turn_id, writers, post_fn \\ &ApiClient.post_message/3) do
    TurnMarkers.post_all(identifier, aiur_turn_id, writers, post_fn)
  end

  # Match the close to the marker post — the bridge SSE for this
  # aiur_turn_id closes on the matching `:aiur_turn_done` broadcast.
  # `nil` from open_aiur_turn_streams/1 means no marker fired (no
  # SessionWriter attached or issue had no identifier); no close
  # broadcast needed.
  @doc false
  @spec close_aiur_turn_streams(Issue.t(), String.t() | nil, term()) :: :ok
  def close_aiur_turn_streams(%Issue{identifier: identifier}, aiur_turn_id, reason)
      when is_binary(identifier) and is_binary(aiur_turn_id) do
    AgentPubSub.broadcast_aiur_turn_done(identifier, aiur_turn_id, reason)
    # mark_closed retains the entry for the cleanup window so a slow
    # bridge subscribe still finalizes with this reason instead of
    # waiting on the broadcast it missed.
    ActiveTurns.mark_closed(identifier, aiur_turn_id, reason)
    :ok
  end

  def close_aiur_turn_streams(_issue, _aiur_turn_id, _reason), do: :ok

  @doc false
  @spec build_turn_prompt_for_test(Issue.t(), keyword(), pos_integer(), pos_integer() | nil) :: String.t()
  def build_turn_prompt_for_test(issue, opts, turn_number, max_turns), do: TurnPrompt.build_turn_prompt(issue, opts, turn_number, max_turns)

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

  @doc false
  @spec write_pause_log(Path.t() | nil, worker_host()) :: :ok
  def write_pause_log(workspace, worker_host) do
    write_pause_log(workspace, worker_host, "Agent paused by operator.")
  end

  @doc false
  @spec write_pause_log(Path.t() | nil, worker_host(), String.t()) :: :ok
  def write_pause_log(workspace, worker_host, message) do
    AgentEventLog.write(workspace, worker_host, %{
      event: :worker_paused,
      timestamp: DateTime.utc_now(),
      last_message: message
    })
  end

  defp trim_hook_output(output) when is_binary(output) do
    output
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp trim_hook_output(output), do: output

  @doc false
  @spec tool_executor(Issue.t(), Path.t() | nil, worker_host()) :: fun()
  def tool_executor(issue, workspace, worker_host) do
    fn tool, arguments ->
      DynamicTool.execute(
        tool,
        arguments,
        alert_emitter: fn name, message, reason, needs_attention, severity ->
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
            worker_host: worker_host,
            reason: reason,
            needs_attention: needs_attention,
            severity: severity
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
      nil ->
        {:error, :no_issue_number}

      current ->
        result = IssueDependencies.declare(current, blocker_number)

        # Add the SubscriptionStore subscription IMMEDIATELY on a
        # successful (or `:already_present`) declare, instead of
        # waiting for the orchestrator's poll-driven
        # `auto_subscribe_for_dependency`. GitHub state can lag, drop,
        # or already-present the dependency due to PR open/close
        # cycles; without the direct subscribe, the blockee's
        # SubscriptionStore never gets `ticket.<blocker>.branch.push`
        # and the blockee never auto-resumes. Idempotent.
        case result do
          {:ok, _} ->
            Aiur.Orchestrator.subscribe_for_declared_blocker(current, blocker_number)
            result

          other ->
            other
        end
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

  # A codex turn that died on an exhausted account quota pauses the agent
  # (instead of burning retries into `agent:error`). Surface a clear operator
  # alert carrying the reset time so the run can be resumed once the quota
  # resets. Only the quota-driven pause carries `kind: :usage_limit_exhausted`;
  # ordinary operator pauses are a no-op here.
  @doc false
  @spec maybe_emit_usage_limit_alert(Issue.t(), Path.t() | nil, worker_host(), map()) :: :ok
  def maybe_emit_usage_limit_alert(issue, workspace, worker_host, %{kind: :usage_limit_exhausted} = pause_payload) do
    reset_hint = pause_payload[:reset_hint]
    backend = pause_payload[:reason]

    reset_suffix = if is_binary(reset_hint), do: " (try again at #{reset_hint})", else: ""
    backend_suffix = if is_binary(backend), do: " Backend detail: #{backend}.", else: ""

    reason =
      "Agent paused: the codex account usage quota is exhausted; retrying cannot help " <>
        "until it resets#{reset_suffix}. Resume the agent after the quota resets.#{backend_suffix}"

    Alerts.emit_system(
      "ticket.#{issue.identifier}.agent.usage_limit_exhausted",
      issue: issue,
      workspace: workspace,
      worker_host: worker_host,
      reason: reason,
      needs_attention: true,
      severity: "warning"
    )

    :ok
  end

  def maybe_emit_usage_limit_alert(_issue, _workspace, _worker_host, _pause_payload), do: :ok

  @doc false
  @spec maybe_emit_more_tokens_alert(Issue.t(), Path.t() | nil, worker_host(), term()) :: :ok
  def maybe_emit_more_tokens_alert(issue, workspace, worker_host, reason) do
    if more_tokens_reason?(reason) do
      Alerts.emit_system(
        "ticket.#{issue.identifier}.agent.error.tokens_exhausted",
        issue: issue,
        workspace: workspace,
        worker_host: worker_host,
        reason: "Agent stopped because its token budget or context limit was exhausted.",
        needs_attention: true,
        severity: "warning"
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

  @doc false
  @spec issue_context(Issue.t()) :: String.t()
  def issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
