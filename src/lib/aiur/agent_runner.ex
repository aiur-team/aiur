defmodule Aiur.AgentRunner do
  @moduledoc """
  Executes a single issue in its workspace with the configured coding agent.
  """

  require Logger

  alias Aiur.{AgentEventLog, CodingAgent, Config, Issue, IssueLog, Tracker, Workspace}
  alias Aiur.AgentRunner.{BootstrapDigest, CommentContext, EventsDigest, MessageHandler, QueueDrain}
  alias Aiur.AgentRunner.{SessionLifecycle, SessionResume, TurnLoop, TurnPrompt, TurnStreams}
  alias Aiur.Codex.SessionRecovery
  alias Aiur.Opencode.ApiClient
  alias Aiur.RunTelemetry.Lifecycle
  alias Aiur.Workspace.Ownership

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host =
      if CodingAgent.remote_worker?(CodingAgent.backend_for(issue)) do
        selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)
      end

    # Make sure a per-issue file writer is running so this session's
    # transcript and alert events land in <repo>.<issue>.log alongside any
    # earlier session's output.
    maybe_attach_issue_log(issue)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        if transient_run_error?(reason, CodingAgent.backend_for(issue)) do
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
  # Executor-closed pane), not a broken agent. Raising on it would exit the
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
  #
  # A recoverable Codex session failure means the current generation cannot
  # safely finish its response. Its delivered queue work is restored before
  # this reaches the runner, so a clean exit lets the orchestrator replace the
  # generation and drain that work exactly once.
  @doc false
  @spec transient_run_error?(term()) :: boolean()
  def transient_run_error?(:repl_gone), do: true
  def transient_run_error?(:prompt_not_delivered), do: true
  def transient_run_error?(:port_closed), do: true
  def transient_run_error?({:port_exit, status}) when is_integer(status), do: true
  def transient_run_error?(_reason), do: false

  @doc false
  @spec transient_run_error?(term(), String.t()) :: boolean()
  def transient_run_error?(reason, "codex"), do: SessionRecovery.recoverable?(reason) or transient_run_error?(reason)
  def transient_run_error?(:port_closed, _backend), do: false
  def transient_run_error?({:port_exit, status}, _backend) when is_integer(status), do: false
  def transient_run_error?(reason, _backend), do: transient_run_error?(reason)

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    attempt_id = Keyword.get(opts, :telemetry_attempt_id)
    setup_operation_id = "workspace:#{System.unique_integer([:positive, :monotonic])}"

    Lifecycle.record(issue.identifier, attempt_id, :workspace_setup, :start, %{
      operation_id: setup_operation_id,
      worker_host: worker_host,
      remote: is_binary(worker_host)
    })

    opts = Keyword.put(opts, :telemetry_setup_operation_id, setup_operation_id)

    lifecycle = %{ticket: issue.identifier, attempt_id: attempt_id}

    telemetry_fun = fn ownership, boundary, outcome ->
      record_workspace_ownership(issue, opts, boundary, outcome, ownership)
    end

    case Ownership.claim(issue.identifier, Aiur.Workspace.Ownership.Registry, telemetry_fun: telemetry_fun) do
      {:ok, ownership} ->
        try do
          run_owned_worker_attempt(ownership, issue, codex_update_recipient, opts, worker_host, lifecycle)
        after
          # The release request is intentionally distinct from the terminal
          # ownership boundary. A guardian may still be reaping a provider;
          # declaring the workspace free before registry removal would make
          # lifecycle telemetry lie about the generation that owns the cwd.
          case Ownership.release_and_wait(ownership) do
            {:ok, _released_ownership} ->
              :ok

            {:error, reason} ->
              Logger.warning("workspace ownership remains contained after release request issue=#{issue.identifier} reason=#{inspect(reason)}")
          end
        end

      {:error, {:workspace_owned, owner}} ->
        record_workspace_ownership_conflict(issue, opts, owner)
        record_workspace_setup_end(issue, opts, :contended, :workspace_owned)

        wait =
          if is_pid(codex_update_recipient) do
            Ownership.wait_for_release(issue.identifier, codex_update_recipient)
          else
            :waiting
          end

        notify_workspace_contention(codex_update_recipient, issue, owner, wait)
        :ok

      {:error, {:workspace_ownership_unavailable, reason}} ->
        record_workspace_setup_end(issue, opts, :failed, :workspace_ownership_unavailable)
        {:error, {:workspace_ownership_unavailable, reason}}
    end
  end

  defp run_owned_worker_attempt(ownership, issue, codex_update_recipient, opts, worker_host, lifecycle) do
    case Workspace.create_for_issue(issue, worker_host, lifecycle: lifecycle) do
      {:ok, workspace} ->
        MessageHandler.send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)
        run_worker_attempt(ownership, workspace, issue, codex_update_recipient, opts, worker_host)

      {:error, reason} ->
        record_workspace_setup_end(issue, opts, :failed, reason)
        {:error, reason}
    end
  end

  defp run_worker_attempt(ownership, workspace, issue, codex_update_recipient, opts, worker_host) do
    case run_worker_attempt_once(ownership, workspace, issue, codex_update_recipient, opts, worker_host) do
      :resume_after_before_run_pause ->
        opts = begin_workspace_setup_retry(issue, opts)
        run_worker_attempt(ownership, workspace, issue, codex_update_recipient, opts, worker_host)

      result ->
        result
    end
  end

  defp run_worker_attempt_once(ownership, workspace, issue, codex_update_recipient, opts, worker_host) do
    result =
      try do
        run_after_before_run(ownership, workspace, issue, codex_update_recipient, opts, worker_host)
      after
        Workspace.run_after_run_hook(workspace, issue, worker_host)
      end

    case result do
      {:before_run_failed, status, output, reason} ->
        pause_for_before_run_failure(workspace, issue, codex_update_recipient, worker_host, status, output, reason)

      {:completed, %Issue{} = completed_issue} ->
        publish_completed_boundary(codex_update_recipient, completed_issue)

      other ->
        other
    end
  end

  defp run_after_before_run(ownership, workspace, issue, codex_update_recipient, opts, worker_host) do
    case Workspace.run_before_run_hook(workspace, issue, worker_host) do
      :ok ->
        run_owned_session(ownership, workspace, issue, codex_update_recipient, opts, worker_host)

      {:error, {:workspace_hook_failed, "before_run", status, output} = reason} ->
        record_workspace_setup_end(issue, opts, :failed, status)
        {:before_run_failed, status, output, reason}

      {:error, reason} ->
        record_workspace_setup_end(issue, opts, :failed, reason)
        {:error, reason}
    end
  end

  defp run_owned_session(ownership, workspace, issue, codex_update_recipient, opts, worker_host) do
    case Ownership.activate(ownership) do
      {:ok, active_ownership} ->
        record_workspace_setup_end(issue, opts, :success, nil)
        :ok = BootstrapDigest.maybe_attach_universal_subscriptions(issue)
        :ok = BootstrapDigest.maybe_enqueue_bootstrap_digest(issue)

        SessionLifecycle.run_session(
          workspace,
          issue,
          codex_update_recipient,
          Keyword.put(opts, :workspace_ownership, active_ownership),
          worker_host
        )

      {:error, reason} ->
        record_workspace_setup_end(issue, opts, :failed, reason)
        {:error, reason}
    end
  end

  defp publish_completed_boundary(codex_update_recipient, issue) do
    # This runs only after the mandatory after_run hook above has returned.
    # A pause request can race the final turn boundary, so release its
    # containment generation before the completed entry becomes replaceable.
    _ = Aiur.PauseContainment.release_target(issue.identifier || issue.id)
    MessageHandler.send_control_state(codex_update_recipient, issue, :completed)
  end

  defp record_workspace_setup_end(issue, opts, outcome, reason) do
    metadata = %{
      operation_id: Keyword.get(opts, :telemetry_setup_operation_id),
      outcome: outcome,
      reason_class: if(is_nil(reason), do: nil, else: Lifecycle.reason_class(reason))
    }

    Lifecycle.record(
      issue.identifier,
      Keyword.get(opts, :telemetry_attempt_id),
      :workspace_setup,
      :end,
      metadata
    )
  end

  defp record_workspace_ownership(issue, opts, boundary, outcome, ownership) do
    metadata =
      ownership
      |> Ownership.telemetry_metadata()
      |> Map.put(:outcome, outcome)

    Lifecycle.record(
      issue.identifier,
      Keyword.get(opts, :telemetry_attempt_id),
      :workspace_ownership,
      boundary,
      metadata
    )
  end

  defp record_workspace_ownership_conflict(issue, opts, {:ok, ownership}) do
    record_workspace_ownership(issue, opts, :point, :contended, ownership)
  end

  defp record_workspace_ownership_conflict(issue, opts, :none) do
    Lifecycle.record(
      issue.identifier,
      Keyword.get(opts, :telemetry_attempt_id),
      :workspace_ownership,
      :point,
      %{outcome: :contended}
    )
  end

  defp notify_workspace_contention(recipient, issue, owner, wait) when is_pid(recipient) do
    send(recipient, {:workspace_setup_contended, issue.id, issue.identifier, owner, wait})
    :ok
  end

  defp notify_workspace_contention(_recipient, _issue, _owner, _wait), do: :ok

  defp begin_workspace_setup_retry(issue, opts) do
    operation_id = "workspace:#{System.unique_integer([:positive, :monotonic])}"

    Lifecycle.record(
      issue.identifier,
      Keyword.get(opts, :telemetry_attempt_id),
      :workspace_setup,
      :start,
      %{operation_id: operation_id}
    )

    Keyword.put(opts, :telemetry_setup_operation_id, operation_id)
  end

  defp pause_for_before_run_failure(workspace, issue, codex_update_recipient, worker_host, status, output, reason) do
    Logger.warning("Pausing agent for #{issue_context(issue)} after before_run hook failed status=#{inspect(status)} output=#{inspect(trim_hook_output(output))}")

    write_pause_log(workspace, worker_host, "before_run hook failed; agent paused pending Executor resume.")
    MessageHandler.send_control_state(codex_update_recipient, issue, :paused, %{kind: :before_run_failure})
    wait_for_before_run_resume(issue, codex_update_recipient, reason)
  end

  defp wait_for_before_run_resume(issue, codex_update_recipient, reason) do
    receive do
      {:pause_agent, request_id, generation} when is_integer(request_id) and is_integer(generation) ->
        Logger.info("Agent already paused before run for #{issue_context(issue)} request_id=#{request_id}")

        MessageHandler.send_control_state(codex_update_recipient, issue, :paused, %{
          kind: :before_run_failure,
          request_id: request_id,
          generation: generation
        })

        wait_for_before_run_resume(issue, codex_update_recipient, reason)

      {:pause_agent, request_id} when is_integer(request_id) ->
        Logger.info("Agent already paused before run for #{issue_context(issue)} request_id=#{request_id}")
        MessageHandler.send_control_state(codex_update_recipient, issue, :paused, %{kind: :before_run_failure})
        wait_for_before_run_resume(issue, codex_update_recipient, reason)

      {:resume_agent, request_id, generation} when is_integer(request_id) and is_integer(generation) ->
        Logger.info("Resuming agent after before_run failure for #{issue_context(issue)} request_id=#{request_id}")

        MessageHandler.send_control_state(codex_update_recipient, issue, :working, %{
          request_id: request_id,
          generation: generation
        })

        :resume_after_before_run_pause

      {:resume_agent, request_id} when is_integer(request_id) ->
        Logger.info("Resuming agent after before_run failure for #{issue_context(issue)} request_id=#{request_id}")
        MessageHandler.send_control_state(codex_update_recipient, issue, :working)
        :resume_after_before_run_pause
    end
  end

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
    TurnStreams.post_aiur_turn_markers(identifier, aiur_turn_id, writers, post_fn)
  end

  @doc false
  @spec current_comment_context_events_for_test(Issue.t(), map()) :: [map()]
  def current_comment_context_events_for_test(issue, fetchers) when is_map(fetchers) do
    CommentContext.events(issue, fetchers)
  end

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

  @doc false
  @spec best_effort_queue_bookkeeping(:ok | {:error, term()}, atom(), Issue.t()) :: :ok
  def best_effort_queue_bookkeeping(result, op, issue), do: TurnLoop.best_effort_queue_bookkeeping(result, op, issue)

  @doc false
  @spec turn_done_reason(term()) :: :done | :input_required | {:failed, term()}
  def turn_done_reason(result), do: TurnLoop.turn_done_reason(result)

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
  @spec build_turn_prompt_for_test(Issue.t(), keyword(), pos_integer(), pos_integer() | nil) :: String.t()
  def build_turn_prompt_for_test(issue, opts, turn_number, max_turns),
    do: TurnPrompt.build_turn_prompt(issue, opts, turn_number, max_turns)

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

  defp maybe_attach_issue_log(%Issue{tracker_identity: %Aiur.TrackerIdentity{} = identity}), do: IssueLog.attach(identity)
  defp maybe_attach_issue_log(%Issue{identifier: identifier}) when is_binary(identifier), do: IssueLog.attach(identifier)
  # No bare-map clause: `run/3` calls `CodingAgent.backend_for/1` first, which
  # constrains the argument to `%Issue{}`, so a plain map never reaches here.
  defp maybe_attach_issue_log(_), do: :ok

  @doc false
  @spec write_pause_log(Path.t() | nil, worker_host()) :: :ok
  def write_pause_log(workspace, worker_host), do: write_pause_log(workspace, worker_host, "Agent paused by Executor.")

  @doc false
  @spec write_pause_log(Path.t() | nil, worker_host(), String.t()) :: :ok
  def write_pause_log(workspace, worker_host, message) do
    AgentEventLog.write(workspace, worker_host, %{
      event: :worker_paused,
      timestamp: DateTime.utc_now(),
      last_message: message
    })
  end

  defp trim_hook_output(output) when is_binary(output), do: output |> String.trim() |> String.slice(0, 500)
  defp trim_hook_output(output), do: output

  @doc false
  @spec issue_context(Issue.t()) :: String.t()
  def issue_context(%Issue{id: issue_id, identifier: identifier}), do: "issue_id=#{issue_id} issue_identifier=#{identifier}"
end
