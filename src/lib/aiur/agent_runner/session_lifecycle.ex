defmodule Aiur.AgentRunner.SessionLifecycle do
  @moduledoc false
  require Logger
  alias Aiur.AgentRunner.DispatchSelectionEvent
  alias Aiur.AgentRunner.MessageHandler
  alias Aiur.AgentRunner.ModelLabelRefresh
  alias Aiur.AgentRunner.SessionContainment
  alias Aiur.AgentRunner.SessionDisplay
  alias Aiur.AgentRunner.SessionIdentity
  alias Aiur.AgentRunner.SessionOptions
  alias Aiur.AgentRunner.SessionResume
  alias Aiur.AgentRunner.SessionStartup
  alias Aiur.AgentRunner.TurnBudget
  alias Aiur.AgentRunner.TurnLoop
  alias Aiur.Claude.DisplayTailer
  alias Aiur.CodingAgent
  alias Aiur.Issue
  alias Aiur.Signal
  alias Aiur.Tracker
  alias Aiur.Workspace.Ownership

  import SessionContainment,
    only: [
      report_repl_session: 3,
      report_pause_containment: 3,
      workspace_process_group_tracker: 1,
      workspace_provider_tracker: 1,
      workspace_cleanup_tracker: 1,
      with_expected_provider: 5,
      cancel_pre_spawn_provider_expectation: 2,
      mark_provider_cleanup_unknown: 2
    ]

  import SessionDisplay,
    only: [put_live_conversation_session_id: 2, maybe_put_display_authority: 2, current_display_source_opts: 2, maybe_put_display_source_resolver: 2, maybe_start_display_tailer: 4]

  import SessionStartup, only: [start_with_telemetry: 7, record_session_start_failure: 3]
  @type worker_host :: String.t() | nil

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
         effort: Map.get(session, :effort),
         account: Map.get(session, :account_name),
         account_selection_reason: Map.get(session, :account_selection_reason)
       }}
    )

    :ok
  end

  def report_session_execution(_recipient, _issue, _session), do: :ok

  @doc false
  @spec run_session(Path.t(), Issue.t(), pid() | nil, keyword(), worker_host()) ::
          :ok | {:completed, Issue.t()} | {:error, term()} | {:account_selection_wait, String.t()}
  def run_session(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, TurnBudget.max_turns_for(issue))
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

    ModelLabelRefresh.maybe_alert(
      issue,
      workspace,
      worker_host,
      session_backend,
      model,
      Keyword.get(opts, :model_label_deferred),
      Keyword.get(opts, :model_label, [])
    )

    maybe_trust_remote_control_workspace(workspace, rc?, worker_host, fn ws ->
      Aiur.Orchestrator.ensure_remote_control_trust(orchestrator, ws)
    end)

    lifecycle_attempt_id = Keyword.get(opts, :telemetry_attempt_id)

    Signal.lifecycle(issue.identifier, lifecycle_attempt_id, :agent_spinup, :start, %{
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
      orchestrator: orchestrator,
      update_recipient: codex_update_recipient
    }

    # Claim a provisional provider before opening a port or tmux pane. If this
    # runner dies in the tiny interval before backend metadata arrives, the
    # guardian remains fail-closed rather than replacing the live provider's
    # workspace underneath it.
    case Keyword.get(session_opts, :account_selection_wait) do
      reset_at when is_binary(reset_at) ->
        Signal.lifecycle(
          issue.identifier,
          lifecycle_attempt_id,
          :agent_spinup,
          :end,
          %{
            operation_id: "session",
            backend: session_backend,
            outcome: :paused,
            reason_class: Signal.reason_class(:usage_limit_exhausted)
          }
        )

        {:account_selection_wait, reset_at}

      nil ->
        with_expected_provider(
          Keyword.get(opts, :workspace_ownership),
          if(is_nil(worker_host), do: :local, else: :remote),
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
  end

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
    case start_with_telemetry(
           workspace,
           issue,
           worker_host,
           ownership,
           session_context.session_opts,
           start_fun,
           codex_update_recipient
         ) do
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
        Signal.lifecycle(issue.identifier, session_context.lifecycle_attempt_id, :agent_spinup, :end, %{
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
    report_session_execution(codex_update_recipient, issue, session)
    DispatchSelectionEvent.write(workspace, worker_host, issue)
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
    Process.put(:handoff_display_tailer, display_tailer)
    opts = maybe_put_display_source_resolver(opts, display_tailer)

    # A resumed thread already carries the original task + full prior turn
    # history, so its first turn must continue rather than replay the
    # heavyweight cold-start prompt — mirroring the in-process turn N+1 flow.
    opts = SessionResume.put_first_turn_opts(opts, session, issue.identifier)

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

  @spec session_workspace(map()) :: Path.t() | nil
  defdelegate session_workspace(session), to: SessionIdentity
  @spec session_worker_host(map()) :: worker_host()
  defdelegate session_worker_host(session), to: SessionIdentity
  @spec session_backend!(map()) :: String.t()
  defdelegate session_backend!(session), to: SessionIdentity
  @spec session_backend_label(map()) :: String.t()
  defdelegate session_backend_label(session), to: SessionIdentity
  @spec stop_session_with_ownership(map(), Ownership.lease() | nil, (map() -> term())) :: term()
  defdelegate stop_session_with_ownership(session, ownership, stop_fun \\ &CodingAgent.stop_session/1), to: SessionContainment

  @spec track_session_containment(Ownership.lease() | nil, map(), worker_host()) ::
          :ok | {:error, :workspace_ownership_lost}
  defdelegate track_session_containment(ownership, session, worker_host), to: SessionContainment

  @spec resolve_session_options(Issue.t(), keyword(), worker_host()) ::
          {String.t(), boolean(), keyword()}
  defdelegate resolve_session_options(issue, opts, worker_host), to: SessionOptions
  @spec remote_session_backend(String.t(), boolean()) :: String.t()
  defdelegate remote_session_backend(backend, rc?), to: SessionOptions
  @spec maybe_trust_remote_control_workspace(Path.t(), boolean(), worker_host(), fun()) :: :ok
  defdelegate maybe_trust_remote_control_workspace(workspace, rc?, worker_host, trust_fun), to: SessionOptions
  @spec rc_session_name(Issue.t(), String.t() | nil) :: String.t()
  defdelegate rc_session_name(issue, repo \\ Tracker.project_identity()), to: SessionOptions
  @spec display_tailer_handler(Issue.t(), String.t(), keyword()) :: (map() -> :ok)
  defdelegate display_tailer_handler(issue, backend, opts), to: SessionDisplay

  @spec display_tailer_source_handler(Issue.t(), String.t(), keyword()) ::
          (DisplayTailer.source_event() -> :ok | {:error, term()})
  defdelegate display_tailer_source_handler(issue, backend, opts), to: SessionDisplay
  @spec should_display_tail?(String.t() | nil, boolean(), String.t() | nil) :: boolean()
  defdelegate should_display_tail?(backend, rc?, identifier), to: SessionDisplay
  @spec start_adopted_display(map(), Issue.t(), keyword()) :: {pid() | nil, keyword()}
  defdelegate start_adopted_display(session, issue, opts), to: SessionDisplay
  @spec stop_display_tailer(pid() | nil) :: :ok
  defdelegate stop_display_tailer(pid), to: SessionDisplay
  @spec start_agent_session(Path.t(), keyword(), fun()) :: {:ok, map()} | {:error, term()}
  defdelegate start_agent_session(workspace, opts, start_fun \\ &CodingAgent.start_session/2), to: SessionStartup
  @spec maybe_alert_unsupported_model(Issue.t(), Path.t() | nil, worker_host(), String.t(), String.t() | nil) :: :ok
  defdelegate maybe_alert_unsupported_model(issue, workspace, worker_host, backend, model), to: SessionStartup
end
