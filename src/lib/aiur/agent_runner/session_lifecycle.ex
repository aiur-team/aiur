defmodule Aiur.AgentRunner.SessionLifecycle do
  @moduledoc false
  require Logger
  alias Aiur.{AgentPubSub, Alerts, CodingAgent, Config, Issue, ModelDiscovery, Tracker}
  alias Aiur.AgentRunner.{MessageHandler, SessionResume, TurnLoop}
  alias Aiur.Claude.{AdapterHealth, DisplayTailer, RemoteControl, Telemetry}
  alias Aiur.LiveConversation.Source
  alias Aiur.RunTelemetry.Lifecycle
  alias Aiur.Workspace.Ownership
  @type worker_host :: String.t() | nil
  # The live session's OS-level runtime (REPL pane + agent os pid, or the
  # headless wrapper's bash pid) is owned by this runner task. An
  # abort/shutdown brutally kills the task, skipping the `after
  # stop_session` cleanup, so report it to the orchestrator's running
  # entry — the only place an abort path can still reach it. What gets
  # reported is the backend's registry-declared `runtime_report`
  # capability (`Aiur.CodingAgent.runtime_report/1`).
  defp report_repl_session(recipient, %Issue{id: issue_id}, session)
       when is_binary(issue_id) and is_pid(recipient) do
    case session_runtime_info(session) do
      nil ->
        :ok

      info ->
        send(recipient, {:repl_session_runtime, issue_id, info})
        :ok
    end
  end

  defp report_repl_session(_recipient, _issue, _session), do: :ok

  @doc false
  @spec report_session_execution(pid() | nil, Issue.t(), map()) :: :ok
  def report_session_execution(recipient, %Issue{id: issue_id}, session)
      when is_binary(issue_id) and is_pid(recipient) and is_map(session) do
    send(
      recipient,
      {:session_execution_info, issue_id,
       %{
         backend: session_backend_label(session),
         requested_model: Map.get(session, :model),
         effort: Map.get(session, :effort)
       }}
    )

    :ok
  end

  def report_session_execution(_recipient, _issue, _session), do: :ok

  defp report_pause_containment(recipient, %Issue{id: issue_id}, %{containment: containment, metadata: metadata})
       when is_pid(recipient) and is_binary(issue_id) and is_map(containment) do
    send(recipient, {
      :pause_containment_runtime,
      issue_id,
      %{generation: containment[:generation], process_group_id: metadata[:agent_process_group_id]}
    })

    :ok
  end

  defp report_pause_containment(_recipient, _issue, _session), do: :ok

  defp session_runtime_info(session) do
    case CodingAgent.runtime_report(session_backend!(session)) do
      :repl_pane ->
        %{
          pane_id: Map.get(session, :pane_id),
          os_pid: Map.get(session, :os_pid),
          session_url: Map.get(session, :session_url)
        }

      :headless_wrapper ->
        case headless_os_pid(session) do
          nil -> nil
          pid -> %{headless_os_pid: pid, headless_process_group_id: process_group_id(session)}
        end

      nil ->
        nil
    end
  end

  defp headless_os_pid(%{metadata: metadata}) when is_map(metadata) do
    pid = metadata[:provider_pid] || metadata[:claude_app_server_pid]

    case pid do
      pid when is_binary(pid) ->
        case Integer.parse(pid) do
          {n, _} -> n
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp headless_os_pid(_session), do: nil

  defp process_group_id(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :agent_process_group_id) do
      process_group_id when is_integer(process_group_id) and process_group_id > 0 ->
        process_group_id

      process_group_id when is_binary(process_group_id) ->
        case Integer.parse(process_group_id) do
          {value, ""} when value > 0 -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp process_group_id(_session), do: nil

  defp workspace_process_group_tracker(nil), do: fn _process_group_id -> :ok end

  defp workspace_process_group_tracker(ownership) do
    fn process_group_id -> Ownership.track_process_group(ownership, process_group_id) end
  end

  defp workspace_provider_tracker(nil), do: fn _provider -> :ok end

  defp workspace_provider_tracker(ownership) do
    fn provider -> Ownership.track_provider(ownership, provider) end
  end

  defp workspace_cleanup_tracker(nil), do: fn _outcome -> :ok end

  defp workspace_cleanup_tracker(ownership) do
    fn
      :succeeded -> Ownership.mark_provider_cleanup_succeeded(ownership)
      _outcome -> Ownership.mark_provider_cleanup_unknown(ownership)
    end
  end

  @doc false
  @spec run_session(Path.t(), Issue.t(), pid() | nil, keyword(), worker_host()) ::
          :ok | {:completed, Issue.t()} | {:error, term()}
  def run_session(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.agent_max_turns_for(issue))
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    orchestrator = Keyword.get(opts, :orchestrator, Aiur.Orchestrator)

    {session_backend, rc?, session_opts} = resolve_session_options(issue, opts, worker_host)

    session_opts =
      session_opts
      |> Keyword.put(
        :on_process_group_started,
        workspace_process_group_tracker(Keyword.get(opts, :workspace_ownership))
      )
      |> Keyword.put(:on_provider_started, workspace_provider_tracker(Keyword.get(opts, :workspace_ownership)))
      |> Keyword.put(:on_provider_cleanup, workspace_cleanup_tracker(Keyword.get(opts, :workspace_ownership)))

    model = Keyword.fetch!(session_opts, :model)
    effort = Keyword.fetch!(session_opts, :effort)

    Logger.info("Resolved backend for #{Aiur.AgentRunner.issue_context(issue)} backend=#{session_backend} model=#{inspect(model)} effort=#{inspect(effort)} remote_control=#{rc?}")

    maybe_alert_unsupported_model(issue, workspace, worker_host, session_backend, model)

    maybe_trust_remote_control_workspace(workspace, rc?, worker_host, fn ws ->
      Aiur.Orchestrator.ensure_remote_control_trust(orchestrator, ws)
    end)

    lifecycle_attempt_id = Keyword.get(opts, :telemetry_attempt_id)

    Lifecycle.record(issue.identifier, lifecycle_attempt_id, :agent_spinup, :start, %{
      operation_id: "session",
      backend: session_backend,
      worker_host: worker_host,
      remote: is_binary(worker_host)
    })

    session_context = %{
      lifecycle_attempt_id: lifecycle_attempt_id,
      max_turns: max_turns,
      session_backend: session_backend,
      session_opts: session_opts,
      rc?: rc?,
      issue_state_fetcher: issue_state_fetcher,
      orchestrator: orchestrator
    }

    # Claim a provisional provider before opening a port or tmux pane. If this
    # runner dies in the tiny interval before backend metadata arrives, the
    # guardian remains fail-closed rather than replacing the live provider's
    # workspace underneath it.
    with_expected_provider(
      Keyword.get(opts, :workspace_ownership),
      fn ownership ->
        start_expected_session(
          workspace,
          issue,
          codex_update_recipient,
          opts,
          worker_host,
          ownership,
          session_context,
          Keyword.get(opts, :session_start_fun, &CodingAgent.start_session/2)
        )
      end,
      issue,
      session_context
    )
  end

  defp with_expected_provider(nil, start, _issue, _session_context), do: start.(nil)

  defp with_expected_provider(ownership, start, issue, session_context) do
    case Ownership.expect_provider(ownership) do
      :ok ->
        start.(ownership)

      {:error, reason} = error ->
        record_session_start_failure(issue, session_context, reason)
        error
    end
  end

  defp cancel_pre_spawn_provider_expectation(ownership, reason) do
    if pre_spawn_start_error?(reason), do: Ownership.cancel_provider_expectation(ownership)
    :ok
  end

  defp mark_provider_cleanup_unknown(ownership, {:repl_cleanup_failed, _reason}),
    do: Ownership.mark_provider_cleanup_unknown(ownership)

  defp mark_provider_cleanup_unknown(_ownership, _reason), do: :ok

  # These are the only errors whose producers prove that no backend process
  # exists. Keep this deliberately narrow: any error after a port or pane may
  # have escaped containment discovery, so its expectation must stay
  # fail-closed for the guardian to reap or prove it gone.
  defp pre_spawn_start_error?(reason)
       when reason in [
              :bash_not_found,
              :no_tmux,
              :no_tmux_executable,
              :remote_control_requires_dashboard,
              :receiver_unavailable,
              :missing_tracker_identity,
              :remote_worker_unsupported,
              :invalid_correlation,
              :capability_unavailable
            ],
       do: true

  # Codex and Claude reject their workspace root before invoking their spawn
  # adapters. The local/root and remote-path variants intentionally carry
  # different arities, so both belong to the authoritative no-spawn set.
  defp pre_spawn_start_error?({:invalid_workspace_cwd, _, _}), do: true
  defp pre_spawn_start_error?({:invalid_workspace_cwd, _, _, _}), do: true
  defp pre_spawn_start_error?(_reason), do: false

  defp start_expected_session(
         workspace,
         issue,
         codex_update_recipient,
         opts,
         worker_host,
         ownership,
         session_context,
         start_fun
       ) do
    case start_with_telemetry(workspace, issue, worker_host, ownership, session_context.session_opts, start_fun) do
      {:ok, session} ->
        run_contained_session(
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          worker_host,
          ownership,
          session_context
        )

      {:error, reason} = error ->
        cancel_pre_spawn_provider_expectation(ownership, reason)
        mark_provider_cleanup_unknown(ownership, reason)
        record_session_start_failure(issue, session_context, reason)
        error
    end
  end

  defp start_with_telemetry(workspace, issue, worker_host, ownership, session_opts, start_fun) do
    case prepare_telemetry_launch(issue, worker_host, ownership, session_opts) do
      {:ok, telemetry_launch} ->
        launch_opts = with_telemetry_launch_opts(session_opts, telemetry_launch, issue, worker_host, ownership)

        case start_agent_session(workspace, launch_opts, start_fun) do
          {:ok, session} ->
            revoke_unclaimed_telemetry_launch(session, telemetry_launch)
            {:ok, session}

          {:error, _reason} = error ->
            _ = Telemetry.revoke(telemetry_launch)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare_telemetry_launch(_issue, _worker_host, nil, _session_opts), do: {:ok, nil}

  defp prepare_telemetry_launch(issue, worker_host, ownership, session_opts) do
    if Keyword.get(session_opts, :backend) in ["claude", "claude-repl"] do
      Telemetry.prepare_launch(issue,
        attempt_id: Keyword.get(session_opts, :attempt_id),
        workspace_ownership: ownership,
        backend: Keyword.get(session_opts, :backend),
        worker_host: worker_host
      )
    else
      {:ok, nil}
    end
  end

  defp with_telemetry_launch_opts(session_opts, nil, _issue, _worker_host, _ownership), do: session_opts

  defp with_telemetry_launch_opts(session_opts, telemetry_launch, issue, worker_host, ownership) do
    fallback_launch_fun = fn fallback_backend ->
      Telemetry.prepare_launch(issue,
        attempt_id: Keyword.get(session_opts, :attempt_id),
        workspace_ownership: ownership,
        backend: fallback_backend,
        worker_host: worker_host
      )
    end

    session_opts
    |> Keyword.put(:telemetry_launch, telemetry_launch)
    |> Keyword.put(:telemetry_fallback_launch_fun, fallback_launch_fun)
  end

  defp revoke_unclaimed_telemetry_launch(_session, nil), do: :ok

  defp revoke_unclaimed_telemetry_launch(%{telemetry_launch: %{id: id}}, %{id: id}) when is_reference(id), do: :ok

  defp revoke_unclaimed_telemetry_launch(_session, telemetry_launch) do
    # A REPL can fall back to the headless adapter after a failed pane spawn.
    # Never reuse a capability whose trusted backend correlation says REPL for
    # that replacement process; the fallback remains visibly uncovered until a
    # fresh, correctly correlated launch is prepared.
    Telemetry.revoke(telemetry_launch)
  end

  defp run_contained_session(
         session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         worker_host,
         ownership,
         session_context
       ) do
    case track_session_containment(ownership, session, worker_host) do
      :ok ->
        Lifecycle.record(issue.identifier, session_context.lifecycle_attempt_id, :agent_spinup, :end, %{
          operation_id: "session",
          backend: session_context.session_backend,
          outcome: :success
        })

        run_session_turn_loop(
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          worker_host,
          ownership,
          session_context
        )

      {:error, _reason} = error ->
        stop_session_with_ownership(session, ownership)
        error
    end
  end

  defp run_session_turn_loop(
         session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         worker_host,
         ownership,
         session_context
       ) do
    maybe_report_claude_adapter_health(issue, workspace, worker_host, session_backend_label(session), opts)
    report_session_execution(codex_update_recipient, issue, session)

    # Persist the live session handle so the next aiur restart can resume it.
    SessionResume.persist_session_handle(session, issue.identifier, worker_host)
    SessionResume.log_resume_outcome(issue, session, Keyword.get(session_context.session_opts, :resume_thread_id))
    report_repl_session(codex_update_recipient, issue, session)
    report_pause_containment(codex_update_recipient, issue, session)

    display_authority? =
      should_display_tail?(session_backend!(session), session_context.rc?, issue.identifier)

    opts =
      opts
      |> put_live_conversation_session_id(session)
      |> maybe_put_display_authority(display_authority?)

    display_tailer = maybe_start_display_tailer(session, issue, session_context.rc?, opts)
    opts = maybe_put_display_source_resolver(opts, display_tailer)

    # A resumed thread already carries the original task + full prior turn
    # history, so its first turn must continue rather than replay the
    # heavyweight cold-start prompt — mirroring the in-process turn N+1 flow.
    opts = Keyword.put(opts, :resumed, SessionResume.session_resumed?(session))

    try do
      result =
        TurnLoop.run_turns(
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          session_context.issue_state_fetcher,
          session_context.orchestrator,
          worker_host,
          1,
          session_context.max_turns
        )

      # The provider may have fallen back (for example, from claude-repl to
      # claude). Conversation ingestion keys every event by the backend tagged
      # on the actual session, so terminal health must close that same source.
      MessageHandler.finish_live_conversation(
        issue,
        session_backend_label(session),
        result,
        current_display_source_opts(opts, display_tailer)
      )

      result
    catch
      kind, reason ->
        MessageHandler.mark_live_conversation_degraded(
          issue,
          session_backend_label(session),
          current_display_source_opts(opts, display_tailer)
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      stop_display_tailer(display_tailer)
      stop_session_with_ownership(session, ownership)
    end
  end

  defp put_live_conversation_session_id(opts, %{thread_id: thread_id})
       when is_binary(thread_id) and thread_id != "" do
    Keyword.put(opts, :session_id, thread_id)
  end

  defp put_live_conversation_session_id(opts, _session), do: opts

  defp maybe_put_display_authority(opts, true),
    do: Keyword.put(opts, :live_conversation_authority, :display_tailer)

  defp maybe_put_display_authority(opts, false), do: opts

  defp current_display_source_opts(opts, nil), do: opts

  defp current_display_source_opts(opts, display_tailer) do
    case DisplayTailer.current_session(display_tailer) do
      session_id when is_binary(session_id) and session_id != "" ->
        Keyword.put(opts, :session_id, session_id)

      _other ->
        opts
    end
  catch
    :exit, _reason -> opts
  end

  defp maybe_put_display_source_resolver(opts, nil), do: opts

  defp maybe_put_display_source_resolver(opts, display_tailer) do
    opts
    |> Keyword.put(:live_conversation_source_resolver, fn ->
      DisplayTailer.current_session(display_tailer)
    end)
    |> Keyword.put(:live_conversation_operator_buffer, fn item, occurred_at ->
      DisplayTailer.buffer_operator_delivery(display_tailer, item, occurred_at)
    end)
  end

  @doc false
  @spec stop_session_with_ownership(map(), Ownership.lease() | nil, (map() -> term())) :: term()
  def stop_session_with_ownership(session, ownership, stop_fun \\ &CodingAgent.stop_session/1)
      when is_map(session) and is_function(stop_fun, 1) do
    try do
      case stop_fun.(session) do
        {:ok, :cleanup_proven} ->
          _ = Ownership.mark_provider_cleanup_succeeded(ownership)
          :ok

        :ok ->
          _ = Ownership.mark_provider_cleanup_unknown(ownership)
          :ok

        cleanup_failure ->
          _ = Ownership.mark_provider_cleanup_unknown(ownership)
          cleanup_failure
      end
    after
      Telemetry.revoke(Map.get(session, :telemetry_launch))
    end
  catch
    kind, reason ->
      _ = Ownership.mark_provider_cleanup_unknown(ownership)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp record_session_start_failure(issue, session_context, reason) do
    Lifecycle.record(issue.identifier, session_context.lifecycle_attempt_id, :agent_spinup, :end, %{
      operation_id: "session",
      backend: session_context.session_backend,
      outcome: :failed,
      reason_class: Lifecycle.reason_class(reason)
    })
  end

  # A missing local process group is expected for remote workers, headless
  # adapters, and an occasional `ps` lookup miss. The provider itself is still
  # registered, so only send a process-group update when it is meaningful.
  @doc false
  @spec track_session_containment(Ownership.lease() | nil, map(), worker_host()) ::
          :ok | {:error, :workspace_ownership_lost}
  def track_session_containment(nil, _session, _worker_host), do: :ok

  def track_session_containment(ownership, session, worker_host) do
    with :ok <- track_session_process_group(ownership, process_group_id(session)) do
      Ownership.track_provider(ownership, session_provider(session, worker_host))
    end
  end

  defp track_session_process_group(_ownership, nil), do: :ok

  defp track_session_process_group(ownership, process_group_id),
    do: Ownership.track_process_group(ownership, process_group_id)

  defp session_provider(session, worker_host) do
    metadata = Map.get(session, :metadata, %{})

    %{}
    |> maybe_put_provider_pid(metadata[:provider_pid] || metadata[:codex_app_server_pid] || metadata[:claude_app_server_pid])
    |> maybe_put_provider_pid(Map.get(session, :os_pid))
    |> maybe_put_provider_group(process_group_id(session))
    |> maybe_put_remote_provider(worker_host)
    |> maybe_put_provider_processes(worker_host)
    |> maybe_put_in_process_provider()
  end

  # An in-process session (an OpenAI-compatible HTTP agent) has no OS process,
  # process group, or remote host to contain. Mark it explicitly so the
  # workspace guardian accepts it: such a session is a child of the runner and
  # dies with it, so there is nothing to reap on owner death. Without this, the
  # guardian's `valid_provider?` rejects the empty provider and every dispatch
  # fails with `:workspace_ownership_lost` before the first turn. Only mark
  # providers that carry no OS identity; a session that reports a root pid,
  # process group, remote host, or descendants is reaped normally.
  defp maybe_put_in_process_provider(%{} = provider) when map_size(provider) == 0,
    do: Map.put(provider, :in_process, true)

  defp maybe_put_in_process_provider(provider), do: provider

  defp maybe_put_provider_pid(provider, pid) when is_integer(pid) and pid > 0,
    do: Map.put(provider, :root_pid, pid)

  defp maybe_put_provider_pid(provider, pid) when is_binary(pid) do
    case Integer.parse(pid) do
      {value, ""} when value > 0 -> Map.put(provider, :root_pid, value)
      _ -> provider
    end
  end

  defp maybe_put_provider_pid(provider, _pid), do: provider
  defp maybe_put_provider_group(provider, pid) when is_integer(pid) and pid > 0, do: Map.put(provider, :process_group_id, pid)
  defp maybe_put_provider_group(provider, _pid), do: provider
  defp maybe_put_remote_provider(provider, worker_host) when is_binary(worker_host), do: Map.put(provider, :remote, true)
  defp maybe_put_remote_provider(provider, _worker_host), do: provider

  defp maybe_put_provider_processes(provider, worker_host) when is_binary(worker_host), do: provider

  defp maybe_put_provider_processes(%{root_pid: root_pid} = provider, _worker_host),
    do: Map.put(provider, :descendant_pids, RemoteControl.process_tree(root_pid))

  defp maybe_put_provider_processes(provider, _worker_host), do: provider

  @doc false
  @spec resolve_session_options(Issue.t(), keyword(), worker_host()) ::
          {String.t(), boolean(), keyword()}
  def resolve_session_options(issue, opts, worker_host) do
    backend = CodingAgent.backend_for(issue)
    effort = CodingAgent.effort_for(issue)

    rc? =
      (CodingAgent.remote_control_forced?(issue) or CodingAgent.routing_remote?(issue) or
         Config.agent_remote_control?()) and CodingAgent.remote_control?(backend)

    session_backend = remote_session_backend(backend, rc?)

    # Resolved against the transport that actually receives the string, so a
    # generic tag (`codex:sol`) becomes the newest version in that family
    # while an explicitly pinned one stays pinned. An unrecognized model is
    # passed through unchanged and surfaced in `run_session/5` rather than
    # swapped for something else.
    model = CodingAgent.resolve_model(session_backend, CodingAgent.model_for(issue))

    # Rejoin the prior agent thread across an aiur restart instead of cold-
    # starting a fresh conversation that re-discovers the work (issue #378).
    # Only a resumable, local backend with a persisted handle qualifies; any
    # miss degrades silently to a clean start.
    resume_thread_id = SessionResume.load_resume_thread_id(session_backend, worker_host, issue.identifier)

    session_opts =
      [
        backend: session_backend,
        model: model,
        effort: effort,
        worker_host: worker_host,
        remote_control: rc?,
        identifier: issue.identifier,
        attempt_id: Keyword.get(opts, :telemetry_attempt_id)
      ]
      |> maybe_put_rc_name(rc?, issue)
      |> SessionResume.maybe_put_resume_thread_id(resume_thread_id)

    {session_backend, rc?, session_opts}
  end

  # Mirror the full claude transcript into the opencode pane for an RC claude-repl
  # agent, so the pane and Remote Control channel are two views of one conversation.
  # Headless/codex/RC-off sessions stream their own rich transcript and are left
  # untouched. Started UNLINKED with `owner: self()` so display failure never affects the run.
  defp maybe_start_display_tailer(session, issue, rc?, opts) do
    backend = session_backend!(session)

    if should_display_tail?(backend, rc?, issue.identifier) do
      # DISPLAY-ONLY: broadcast straight to the opencode pane's transcript
      # topic. Do NOT route through codex_message_handler — that also does
      # per-record AgentEventLog.write (disk) and send_codex_update (to the
      # shared run recipient), so a `from: :start` backfill burst would hammer
      # both. The pane render only needs the transcript broadcast.
      on_message = display_tailer_handler(issue, backend, opts)
      on_source = display_tailer_source_handler(issue, backend, opts)
      on_operator_delivery = display_tailer_operator_delivery_handler(issue, backend, opts)

      # Until a hook identifies a readable transcript, the sole authoritative
      # RC conversation source is unavailable. Ordinary provider activation is
      # suppressed by `:live_conversation_authority` and cannot clear this.
      _ = MessageHandler.mark_live_conversation_degraded(issue, backend, opts)

      case DisplayTailer.start(
             identifier: issue.identifier,
             on_message: on_message,
             on_source: on_source,
             on_operator_delivery: on_operator_delivery,
             initial_session_id: Keyword.get(opts, :session_id),
             log_context: "#{Aiur.AgentRunner.issue_context(issue)} backend=#{backend}",
             owner: self()
           ) do
        {:ok, pid} ->
          pid

        {:error, reason} ->
          Logger.warning(
            "display_tailer start_failed #{Aiur.AgentRunner.issue_context(issue)} " <>
              "backend=#{backend} session=#{opaque_live_session(opts)} " <>
              "reason_class=#{Lifecycle.reason_class(reason)}"
          )

          nil
      end
    else
      nil
    end
  end

  @doc false
  @spec display_tailer_handler(Issue.t(), String.t(), keyword()) :: (map() -> :ok)
  def display_tailer_handler(%Issue{identifier: identifier} = issue, backend, opts)
      when is_binary(identifier) and is_binary(backend) and is_list(opts) do
    fn
      %{
        source_session_id: session_id,
        projection_ingress: :display_backfill,
        transcript_event: event
      }
      when is_binary(session_id) and is_map(event) ->
        AgentPubSub.broadcast_transcript(identifier, event)

      %{source_session_id: session_id, transcript_event: event}
      when is_binary(session_id) and is_map(event) ->
        AgentPubSub.broadcast_transcript(identifier, event)

        MessageHandler.observe_display_transcript(
          issue,
          event,
          backend,
          Keyword.put(opts, :session_id, session_id)
        )

      _ ->
        :ok
    end
  end

  @doc false
  @spec display_tailer_source_handler(Issue.t(), String.t(), keyword()) ::
          (DisplayTailer.source_event() -> :ok | {:error, term()})
  def display_tailer_source_handler(%Issue{} = issue, backend, opts)
      when is_binary(backend) and is_list(opts) do
    fn
      {:available, prior_session, next_session, %{backfill?: backfill?}}
      when is_boolean(backfill?) ->
        opts = Keyword.put(opts, :live_conversation_history_known?, not backfill?)

        MessageHandler.replace_live_conversation_source(
          issue,
          backend,
          prior_session,
          next_session,
          opts
        )

      {:available, prior_session, next_session} ->
        MessageHandler.replace_live_conversation_source(
          issue,
          backend,
          prior_session,
          next_session,
          opts
        )

      {:unavailable, prior_session, next_session, _reason} ->
        opts = Keyword.put(opts, :live_conversation_history_known?, false)

        _ =
          MessageHandler.replace_live_conversation_source(
            issue,
            backend,
            prior_session,
            next_session,
            opts
          )

        MessageHandler.mark_live_conversation_degraded(
          issue,
          backend,
          Keyword.put(opts, :session_id, next_session)
        )

      _other ->
        :ok
    end
  end

  defp display_tailer_operator_delivery_handler(issue, backend, opts) do
    fn item, occurred_at, session_id ->
      opts =
        opts
        |> Keyword.put(:session_id, session_id)
        |> Keyword.put(:occurred_at, occurred_at)
        |> Keyword.delete(:live_conversation_authority)

      MessageHandler.observe_operator_delivery(issue, item, backend, opts)
    end
  end

  defp opaque_live_session(opts) do
    Source.opaque_session_id(Keyword.get(opts, :session_id)) ||
      "session:unresolved"
  end

  # Only a backend that declares the `rc_display_tail` capability (the
  # hook-driven RC REPL) feeds the display tailer. A spawn-fallback
  # headless session, codex, or an RC-off REPL streams its own rich
  # transcript and must not get a second display source.
  @doc false
  @spec should_display_tail?(String.t() | nil, boolean(), String.t() | nil) :: boolean()
  def should_display_tail?(backend, rc?, identifier) do
    rc? and CodingAgent.rc_display_tail?(backend) and is_binary(identifier)
  end

  defp stop_display_tailer(nil), do: :ok

  defp stop_display_tailer(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  # The `--remote-control <name>` string is what the Executor sees as the
  # chat title in the Claude app / mobile, so derive it from the issue
  # ("Aiur: Actions #99 - Title") rather than the opaque `aiur-repl-<pid>-<n>`
  # window name. Only set when RC is active; headless and RC-off REPL sessions
  # keep the default name.
  defp maybe_put_rc_name(opts, true, issue), do: Keyword.put(opts, :rc_name, rc_session_name(issue))
  defp maybe_put_rc_name(opts, false, _issue), do: opts
  # Remote control physically rides the persistent-REPL transport, so an
  # RC-on dispatch is promoted to its registry-declared `remote_transport`
  # (`Aiur.CodingAgent.remote_transport/1`, carrying the resolved model).
  # Backends without the capability — and every RC-off dispatch — run as
  # resolved.
  @doc false
  @spec remote_session_backend(String.t(), boolean()) :: String.t()
  def remote_session_backend(backend, true), do: CodingAgent.remote_transport(backend)
  def remote_session_backend(backend, _rc?), do: backend
  # Seed the workspace trust flag before an RC REPL spawns. RC refuses to
  # start in an untrusted directory; without this the REPL sticks on the
  # trust dialog and silently degrades to the headless backend. Only the
  # local path is trusted — RC is local-only (a remote worker_host's
  # workspace lives on another machine), matching `promote_to_remote`'s
  # guard. A trust failure is logged but not fatal: the degrade path still
  # lands a working headless agent rather than stranding the issue.
  @doc false
  @spec maybe_trust_remote_control_workspace(Path.t(), boolean(), worker_host(), fun()) :: :ok
  def maybe_trust_remote_control_workspace(workspace, rc?, worker_host, trust_fun)

  def maybe_trust_remote_control_workspace(workspace, true, nil, trust_fun)
      when is_binary(workspace) and is_function(trust_fun, 1) do
    case trust_fun.(workspace) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("remote-control workspace trust failed; RC may degrade to headless: workspace=#{workspace} reason=#{inspect(reason)}")
        :ok
    end
  end

  def maybe_trust_remote_control_workspace(_workspace, _rc?, _worker_host, _trust_fun), do: :ok
  # Executor-facing RC chat title: `Aiur: <Repo> #<ID> - <title>`, e.g.
  # `Aiur: Actions #7 - CLI: ENS namespace`. The repo name is the capitalized
  # short name of the configured tracker repo (`its-applekid/actions` ->
  # `Actions`); when the tracker exposes no repo it is omitted, leaving
  # `Aiur: #<ID> - <title>`. `repo` is injectable for tests.
  @doc false
  @spec rc_session_name(Issue.t(), String.t() | nil) :: String.t()
  def rc_session_name(issue, repo \\ Tracker.project_identity()) do
    label = issue.identifier || issue.id
    title = issue.title || ""

    "#{rc_session_prefix(repo)} ##{label} - #{title}"
    |> String.replace(~r/[[:cntrl:]'"`]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 60)
  end

  defp rc_session_prefix(repo) do
    case repo_short_name(repo) do
      nil -> "Aiur:"
      name -> "Aiur: #{name}"
    end
  end

  # Capitalized short name of an `owner/name` repo string; nil when absent or empty.
  # Only the first character is upcased so existing casing (e.g. `myRepo`) survives.
  defp repo_short_name(repo) when is_binary(repo) do
    case repo |> String.split("/") |> List.last() |> String.trim() do
      "" -> nil
      <<first::utf8, rest::binary>> -> String.upcase(<<first::utf8>>) <> rest
    end
  end

  defp repo_short_name(_repo), do: nil

  @doc false
  # Start the resolved backend's session, tagging it with its backend so
  # later dispatch resolves the right adapter. A backend may declare a
  # registry `fallback_backend` (the persistent REPL can fail to start: no
  # tmux, REPL never ready, RC activation failed — and a tmux/RC problem
  # must never strand an issue); on a start failure the fallback backend
  # is tried once, with `:remote_control` stripped, and the reason
  # recorded. `start_fun` is injectable for tests; production uses
  # `CodingAgent.start_session/2`.
  @spec start_agent_session(Path.t(), keyword(), fun()) :: {:ok, map()} | {:error, term()}
  def start_agent_session(workspace, opts, start_fun \\ &CodingAgent.start_session/2) do
    backend = Keyword.fetch!(opts, :backend)
    adapter_opts = Keyword.delete(opts, :attempt_id)

    case start_fun.(workspace, adapter_opts) do
      {:ok, session} ->
        {:ok, tag_session(session, backend, opts)}

      {:error, :remote_control_requires_dashboard} = error ->
        error

      {:error, {:repl_cleanup_failed, _reason}} = error ->
        error

      {:error, reason} = error ->
        case CodingAgent.fallback_backend(backend) do
          nil -> error
          fallback -> start_fallback_session(workspace, opts, start_fun, backend, fallback, reason)
        end
    end
  end

  defp start_fallback_session(workspace, opts, start_fun, backend, fallback, reason) do
    Aiur.Perf.event(:repl_start_fallback, backend: backend, reason: inspect(reason))

    Logger.warning("#{backend} start_session failed (#{inspect(reason)}); falling back to #{fallback}")

    {telemetry_launch, fallback_opts} = Keyword.pop(opts, :telemetry_launch)
    _ = Telemetry.revoke(telemetry_launch)
    {fallback_launch_fun, fallback_opts} = Keyword.pop(fallback_opts, :telemetry_fallback_launch_fun)

    with {:ok, fallback_launch} <- prepare_fallback_telemetry(fallback_launch_fun, fallback) do
      fallback_opts =
        fallback_opts
        |> Keyword.put(:backend, fallback)
        |> Keyword.delete(:remote_control)
        |> maybe_put_telemetry_launch_opt(fallback_launch)

      case start_fun.(workspace, Keyword.delete(fallback_opts, :attempt_id)) do
        {:ok, session} ->
          {:ok, tag_session(session, fallback, fallback_opts)}

        {:error, _} = error ->
          _ = Telemetry.revoke(fallback_launch)
          error
      end
    end
  end

  defp prepare_fallback_telemetry(fun, fallback) when is_function(fun, 1), do: fun.(fallback)
  defp prepare_fallback_telemetry(_fun, _fallback), do: {:ok, nil}

  defp maybe_put_telemetry_launch_opt(opts, nil), do: opts
  defp maybe_put_telemetry_launch_opt(opts, launch), do: Keyword.put(opts, :telemetry_launch, launch)

  defp tag_session(session, backend, opts) do
    session
    |> Map.put(:backend, backend)
    |> Map.put(:model, Keyword.get(opts, :model))
    |> Map.put(:effort, supported_effort(backend, Keyword.get(opts, :effort)))
    |> maybe_put_attempt_id(Keyword.get(opts, :attempt_id))
    |> maybe_put_telemetry_launch_session(Keyword.get(opts, :telemetry_launch))
  end

  defp supported_effort(backend, effort) when is_binary(effort) do
    if effort in CodingAgent.efforts(backend) do
      effort
    else
      Logger.warning(
        "Ignoring effort #{inspect(effort)} for backend #{backend}: not in its supported efforts " <>
          "#{inspect(CodingAgent.efforts(backend))} (pair a model:<effort> label with model:remote to run on a transport that supports effort)"
      )

      nil
    end
  end

  defp supported_effort(_backend, _effort), do: nil

  # A model aiur doesn't recognize is far more likely to be newer than this
  # build than to be wrong, so it is never blocked and never quietly swapped
  # for the backend default — either would hide the real problem. Instead the
  # Executor gets one attention naming both remediations: let `aiur init`
  # discover the new tag, or repoint a retired pin at a generic family tag.
  #
  # "Recognized" spans the curated registry list *and* the provider catalogue
  # cache (`Aiur.ModelDiscovery`), so a model the provider currently serves
  # does not raise an attention just because this build predates it. Reading
  # that set is also what schedules the cache's background refresh; it never
  # blocks this call and an empty cache degrades to the curated list.
  @doc false
  @spec maybe_alert_unsupported_model(Issue.t(), Path.t() | nil, worker_host(), String.t(), String.t() | nil) :: :ok
  def maybe_alert_unsupported_model(issue, workspace, worker_host, backend, model) when is_binary(model) do
    if ModelDiscovery.known_model?(backend, model) do
      :ok
    else
      reason = unsupported_model_reason(backend, model)
      Logger.warning("Unknown model #{inspect(model)} for backend #{backend}: #{reason}")

      Alerts.emit_system("ticket.#{issue.identifier}.agent.attention.unsupported_model",
        issue: issue,
        workspace: workspace,
        worker_host: worker_host,
        reason: reason,
        needs_attention: true,
        severity: "warning"
      )

      :ok
    end
  end

  def maybe_alert_unsupported_model(_issue, _workspace, _worker_host, _backend, _model), do: :ok

  @doc false
  @spec maybe_report_claude_adapter_health(Issue.t(), Path.t() | nil, worker_host(), String.t(), keyword()) :: :ok
  def maybe_report_claude_adapter_health(issue, workspace, nil, "claude", opts) do
    task_start = Keyword.get(opts, :adapter_health_task_start, &Task.start/1)
    reporter = Keyword.get(opts, :adapter_health_reporter, &AdapterHealth.report_runtime/2)

    case task_start.(fn -> reporter.(issue, workspace) end) do
      {:ok, _pid} -> :ok
      _other -> Logger.warning("could not start aiur-claude adapter health check; continuing the Claude session")
    end

    :ok
  rescue
    _error ->
      Logger.warning("could not start aiur-claude adapter health check; continuing the Claude session")
      :ok
  end

  def maybe_report_claude_adapter_health(_issue, _workspace, _worker_host, _backend, _opts), do: :ok

  defp unsupported_model_reason(backend, model) do
    generic = List.first(CodingAgent.model_aliases(backend)) || List.first(CodingAgent.seedable_models(backend))

    "Model #{inspect(model)} is not one aiur knows for the #{backend} backend " <>
      "(known: #{Enum.join(CodingAgent.seedable_models(backend), ", ")}). It is being passed to the backend " <>
      "unchanged — aiur is not substituting a different model. If it is a newly released model, run `aiur init` " <>
      "and accept the offer to create its model tags. If it is a retired version, repoint the issue label or the " <>
      "`agent.routing` entry at a generic tag such as #{inspect(generic)}, which always resolves to the newest " <>
      "model in that family."
  end

  defp maybe_put_attempt_id(session, attempt_id) when is_binary(attempt_id), do: Map.put(session, :attempt_id, attempt_id)
  defp maybe_put_attempt_id(session, _attempt_id), do: session
  defp maybe_put_telemetry_launch_session(session, %{id: id}) when is_reference(id), do: Map.put(session, :telemetry_launch, %{id: id})
  defp maybe_put_telemetry_launch_session(session, _launch), do: session

  @doc false
  @spec session_workspace(map()) :: Path.t() | nil
  def session_workspace(%{workspace: workspace}) when is_binary(workspace), do: workspace
  def session_workspace(_session), do: nil

  @doc false
  @spec session_worker_host(map()) :: worker_host()
  def session_worker_host(%{worker_host: worker_host}), do: worker_host
  def session_worker_host(_session), do: nil

  @unknown_backend "unknown"

  @doc """
  The backend that created this session, for paths where a wrong answer
  changes behaviour.

  Raises when the session carries no binary `:backend`, matching
  `Aiur.CodingAgent`'s refusal to dispatch such a session. There is no global
  default here on purpose: `agent.kind` is the configured *default for new
  work*, not evidence about the session in hand, and substituting it made a
  caller-side bug look like a routine run against the wrong provider
  (issue #1621).

  Use `session_backend_label/1` instead on reporting-only paths.
  """
  @spec session_backend!(map()) :: String.t()
  def session_backend!(%{backend: backend}) when is_binary(backend), do: backend

  def session_backend!(session) do
    raise ArgumentError,
          "cannot resolve the coding-agent backend for session #{inspect(session)}; expected a binary :backend"
  end

  @doc """
  The backend that created this session, for reporting only.

  Returns `#{@unknown_backend}` when the session carries no binary `:backend`.
  Alerts, telemetry, and lifecycle records must never take down a turn, so
  they cannot use `session_backend!/1` — but they must not invent a backend
  either. An alert naming the configured default as the provider that hit a
  usage limit is a confidently wrong reason, which costs more to unwind than
  an honest `#{@unknown_backend}`.
  """
  @spec session_backend_label(map()) :: String.t()
  def session_backend_label(%{backend: backend}) when is_binary(backend), do: backend
  def session_backend_label(_session), do: @unknown_backend
end
