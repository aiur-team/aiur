defmodule Aiur.AgentRunner do
  @moduledoc """
  Executes a single issue in its workspace with the configured coding agent.
  """

  require Logger

  alias Aiur.{AgentEventLog, Config, Issue, IssueLog, Workspace}
  alias Aiur.AgentRunner.{BootstrapDigest, MessageHandler, SessionLifecycle, TurnStreams}
  alias Aiur.Opencode.ApiClient

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
        MessageHandler.send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

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
    MessageHandler.send_control_state(codex_update_recipient, issue, :paused)
    wait_for_before_run_resume(issue, codex_update_recipient, reason)
  end

  defp wait_for_before_run_resume(issue, codex_update_recipient, reason) do
    receive do
      {:pause_agent, request_id} when is_integer(request_id) ->
        Logger.info("Agent already paused before run for #{issue_context(issue)} request_id=#{request_id}")
        MessageHandler.send_control_state(codex_update_recipient, issue, :paused)
        wait_for_before_run_resume(issue, codex_update_recipient, reason)

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

  defp maybe_attach_issue_log(%Issue{identifier: identifier}) when is_binary(identifier), do: IssueLog.attach(identifier)
  defp maybe_attach_issue_log(%{identifier: identifier}) when is_binary(identifier), do: IssueLog.attach(identifier)
  defp maybe_attach_issue_log(_), do: :ok

  @doc false
  @spec write_pause_log(Path.t() | nil, worker_host()) :: :ok
  def write_pause_log(workspace, worker_host), do: write_pause_log(workspace, worker_host, "Agent paused by operator.")

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
