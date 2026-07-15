defmodule Aiur.Orchestrator.RemoteControlMode do
  @moduledoc """
  Owns promotion and demotion of a running agent into remote-control mode.
  All functions execute inside the orchestrator GenServer process.
  """

  alias Aiur.Claude.{RemoteControl, ReplAgent}
  alias Aiur.{CodingAgent, Config}
  alias Aiur.HttpServer
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{Dispatcher, State, StatusReport}
  alias Aiur.Tracker
  require Logger

  @spec set_remote_control(String.t(), boolean()) :: {:ok, :on | :off} | {:error, term()}
  def set_remote_control(issue_identifier, on?),
    do: set_remote_control(Aiur.Orchestrator, issue_identifier, on?)

  @spec set_remote_control(GenServer.server(), String.t(), boolean()) ::
          {:ok, :on | :off} | {:error, term()}
  def set_remote_control(server, issue_identifier, on?)
      when is_binary(issue_identifier) and is_boolean(on?),
      do: control_api_call(server, {:set_remote_control, issue_identifier, on?}, 10_000)

  @spec ensure_remote_control_trust(Path.t()) :: :ok | {:error, term()}
  def ensure_remote_control_trust(workspace),
    do: ensure_remote_control_trust(Aiur.Orchestrator, workspace)

  @spec ensure_remote_control_trust(GenServer.server(), Path.t()) ::
          :ok | {:error, term()}
  def ensure_remote_control_trust(server, workspace) when is_binary(workspace),
    do: control_api_call(server, {:ensure_remote_control_trust, workspace}, 10_000)

  @spec set_remote_control_call(State.t(), String.t(), boolean()) ::
          {:reply, term(), State.t()}
  def set_remote_control_call(%State{} = state, issue_identifier, on?) do
    {reply, state} = set_remote_control_reply(state, issue_identifier, on?)
    StatusReport.notify_dashboard(state)
    {:reply, reply, state}
  end

  @spec ensure_remote_control_trust_call(State.t(), String.t()) ::
          {:reply, term(), State.t()}
  def ensure_remote_control_trust_call(%State{} = state, workspace)
      when is_binary(workspace) do
    {:reply, RemoteControl.ensure_workspace_trusted(workspace, remote_control_trust_opts()), state}
  end

  @doc false
  @spec set_remote_control_reply(State.t(), String.t(), boolean(), keyword()) :: {term(), State.t()}
  def set_remote_control_reply(state, issue_identifier, on?, opts \\ []) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      running_entry when is_map(running_entry) ->
        if on?,
          do: promote_to_remote(state, running_entry, opts),
          else: demote_from_remote(state, running_entry, opts)

      _ ->
        {{:error, :not_running}, state}
    end
  end

  # Promote any running agent (headless `claude` or `codex`) to remote control:
  # add the durable `model:remote` label, stop the current agent, and
  # re-dispatch the same issue. The re-dispatch resolves `claude-repl` + forced
  # RC (the alias from `CodingAgent`) and resumes the transcript by cwd, so the
  # Executor gets a persistent REPL with RC attached on the same conversation.
  defp promote_to_remote(state, running_entry, opts) do
    issue = Map.get(running_entry, :issue)
    workspace = Map.get(running_entry, :workspace_path)
    dashboard_url_fun = Keyword.get(opts, :dashboard_url_fun, &HttpServer.base_url/0)

    cond do
      # Already remote (label present) — toggling on again is a no-op.
      CodingAgent.remote_control_forced?(issue) ->
        {{:ok, :on}, state}

      # v1 is local-only: a remote worker_host means the RC session would
      # attach on the wrong machine.
      not is_nil(Map.get(running_entry, :worker_host)) ->
        {{:error, :remote_unsupported}, state}

      is_nil(workspace) ->
        {{:error, :workspace_unavailable}, state}

      is_nil(dashboard_url_fun.()) ->
        {{:error, :remote_control_requires_dashboard}, state}

      true ->
        label = CodingAgent.remote_control_alias_label()
        relabeled = add_issue_label(issue, label)

        case redispatch_admission(state, relabeled, opts) do
          {:ok, admitted_state} ->
            promote_trusted_workspace(admitted_state, running_entry, relabeled, label, workspace, opts)

          {:error, reason, rejected_state} ->
            {{:error, reason}, rejected_state}
        end
    end
  end

  # Trust the workspace before tearing down the current agent. If trust fails
  # RC cannot attach, so abort with the current agent intact.
  defp promote_trusted_workspace(state, running_entry, relabeled, label, workspace, opts) do
    trust = Keyword.get(opts, :trust_fun, &RemoteControl.ensure_workspace_trusted/2)

    case trust.(workspace, remote_control_trust_opts()) do
      :ok ->
        do_promote_to_remote(state, running_entry, relabeled, label, opts)

      {:error, reason} ->
        Logger.error("Remote Control promote trust failed: #{rc_log_context(running_entry)} workspace=#{workspace} reason=#{inspect(reason)}")

        {{:error, {:rc_trust_failed, reason}}, state}
    end
  end

  defp do_promote_to_remote(state, running_entry, relabeled, label, opts) do
    add_label = Keyword.get(opts, :add_label_fun, &Tracker.add_label/2)

    case add_label.(Map.get(running_entry, :identifier), label) do
      :ok ->
        teardown = Keyword.get(opts, :teardown_fun, &teardown_for_redispatch/2)
        state = teardown.(state, running_entry)
        state = drop_redispatch_entry(state, relabeled.id)

        Logger.info("Remote Control promote; re-dispatching with model:remote: #{rc_log_context(running_entry)}")

        {{:ok, :on}, redispatch_prior_work(state, relabeled, opts)}

      {:error, reason} ->
        Logger.error("Remote Control promote label-add failed: #{rc_log_context(running_entry)} reason=#{inspect(reason)}")

        {{:error, {:rc_label_failed, reason}}, state}
    end
  end

  # Demote a remote-control agent back to the default backend: remove the
  # label, stop the current REPL agent, and re-dispatch. `r` is a true toggle.
  defp demote_from_remote(state, running_entry, opts) do
    issue = Map.get(running_entry, :issue)

    cond do
      # Not remote (no label) — toggling off again is a no-op.
      not CodingAgent.remote_control_forced?(issue) ->
        {{:ok, :off}, state}

      is_nil(Map.get(running_entry, :workspace_path)) ->
        {{:error, :workspace_unavailable}, state}

      true ->
        label = CodingAgent.remote_control_alias_label()
        relabeled = remove_issue_label(issue, label)

        case redispatch_admission(state, relabeled, opts) do
          {:ok, admitted_state} ->
            remove_remote_label_and_redispatch(admitted_state, running_entry, relabeled, label, opts)

          {:error, reason, rejected_state} ->
            {{:error, reason}, rejected_state}
        end
    end
  end

  defp remove_remote_label_and_redispatch(state, running_entry, relabeled, label, opts) do
    remove_label = Keyword.get(opts, :remove_label_fun, &Tracker.remove_label/2)

    case remove_label.(Map.get(running_entry, :identifier), label) do
      :ok ->
        teardown = Keyword.get(opts, :teardown_fun, &teardown_for_redispatch/2)
        state = teardown.(state, running_entry)
        state = drop_redispatch_entry(state, relabeled.id)

        Logger.info("Remote Control demote; re-dispatching as default backend: #{rc_log_context(running_entry)}")

        {{:ok, :off}, redispatch_prior_work(state, relabeled, opts)}

      {:error, reason} ->
        Logger.error("Remote Control demote label-remove failed: #{rc_log_context(running_entry)} reason=#{inspect(reason)}")

        {{:error, {:rc_label_failed, reason}}, state}
    end
  end

  defp redispatch_prior_work(state, issue, opts) do
    dispatch = Keyword.get(opts, :dispatch_fun, &Dispatcher.do_dispatch_issue/5)
    dispatch.(state, issue, nil, nil, prior_work: Config.agent_prior_work_continuation?())
  end

  defp redispatch_admission(state, issue, opts) do
    ready = Keyword.get(opts, :dispatch_ready_fun, &Dispatcher.admit_redispatch/3)

    case ready.(state, issue, nil) do
      {:ok, admitted_state} -> {:ok, admitted_state}
      :ok -> {:ok, state}
      {:error, reason, rejected_state} -> {:error, reason, rejected_state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp drop_redispatch_entry(state, issue_id),
    do: %{state | running: Map.delete(state.running, issue_id)}

  # Stop the current agent cleanly so the same issue can be re-dispatched under
  # a different backend. Mirrors `terminate_running_issue/3`'s task-teardown
  # half (stop RC, kill the REPL pane+pid, close chat streams, demonitor, kill
  # the task) but KEEPS the entry in `state.running` and does NOT clean the
  # workspace or release the claim — the workspace is reused so the re-dispatched
  # agent resumes the transcript by cwd. Demonitor BEFORE killing so the agent
  # :DOWN handler doesn't fire a retry that re-dispatches underneath us.
  #
  # Public (not just used by promote/demote) so other backend-swap flows —
  # `Aiur.Orchestrator.RateLimitFallback`'s codex<->claude reroute — reuse the
  # exact same teardown ordering rather than duplicating it. `reason` is
  # forwarded to the chat-stream close broadcast so a non-RC caller's
  # teardown doesn't get logged/reported under a misleading `:remote_control`
  # cause; it defaults to `:remote_control` so the two existing callers here
  # are unaffected.
  @doc false
  @spec teardown_for_redispatch(State.t(), map(), atom()) :: State.t()
  def teardown_for_redispatch(state, running_entry, reason \\ :remote_control) do
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])
    identifier = Map.get(running_entry, :identifier)
    pid = Map.get(running_entry, :pid)
    ref = Map.get(running_entry, :ref)

    Orchestrator.kill_repl_session(running_entry)
    Orchestrator.close_active_chat_streams(identifier, reason)
    if is_reference(ref), do: Process.demonitor(ref, [:flush])
    if is_pid(pid), do: Orchestrator.terminate_task(pid)

    cleared =
      running_entry
      |> Map.put(:pid, nil)
      |> Map.put(:ref, nil)

    %{
      state
      | running: Map.put(state.running, issue_id, cleared),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  @doc false
  @spec add_issue_label(Issue.t(), String.t()) :: Issue.t()
  def add_issue_label(%Issue{labels: labels} = issue, label) do
    down = String.downcase(label)
    if down in labels, do: issue, else: %{issue | labels: labels ++ [down]}
  end

  @doc false
  @spec remove_issue_label(Issue.t(), String.t()) :: Issue.t()
  def remove_issue_label(%Issue{labels: labels} = issue, label) do
    down = String.downcase(label)
    %{issue | labels: Enum.reject(labels, &(&1 == down))}
  end

  defp rc_log_context(entry) do
    issue_id = get_in(entry, [:issue, Access.key(:id)])
    "issue_id=#{issue_id} issue_identifier=#{Map.get(entry, :identifier)}"
  end

  defp control_api_call(server, request, timeout) do
    if GenServer.whereis(server) do
      GenServer.call(server, request, timeout)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  # Tests redirect the trust-config write off the real `~/.claude.json`.
  @doc false
  @spec remote_control_trust_opts() :: keyword()
  def remote_control_trust_opts do
    case Application.get_env(:aiur, :remote_control_claude_json) do
      path when is_binary(path) -> [path: path]
      _ -> []
    end
  end

  # The indicator reflects a *live* remote session, not the label. The REPL
  # only earns RC mode when it actually attaches and prints its
  # `https://claude.ai/code/session_…` banner, which the runner forwards to
  # `:repl_rc_session_url` (a capability token, never logged). A labeled issue
  # whose RC never attached — degraded to headless, or routed to a backend that
  # has no RC path at all (codex) — has no URL, so it shows no phone icon.
  @doc false
  @spec remote_control_summary(map()) :: %{status: :on, session_url: String.t()} | nil
  def remote_control_summary(entry) do
    issue = Map.get(entry, :issue)

    with true <- is_map(issue) and match?(%Issue{}, issue),
         true <- CodingAgent.remote_control_forced?(issue),
         url when is_binary(url) <- Map.get(entry, :repl_rc_session_url) do
      %{status: :on, session_url: url}
    else
      _ -> nil
    end
  end

  @doc false
  @spec cleanup_stray_remote_control_servers() :: :ok
  def cleanup_stray_remote_control_servers do
    RemoteControl.reap_orphaned_servers()
    ReplAgent.reap_orphaned_panes()
  rescue
    _ -> :ok
  end
end
