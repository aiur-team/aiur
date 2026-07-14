defmodule Aiur.AgentRunner.SessionLifecycle do
  @moduledoc false
  require Logger
  alias Aiur.{AgentPubSub, CodingAgent, Config, Issue, Tracker}
  alias Aiur.AgentRunner.{SessionResume, TurnLoop}
  alias Aiur.Claude.DisplayTailer
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
    case CodingAgent.runtime_report(session_backend(session)) do
      :repl_pane ->
        %{
          pane_id: Map.get(session, :pane_id),
          os_pid: Map.get(session, :os_pid),
          session_url: Map.get(session, :session_url)
        }

      :headless_wrapper ->
        case headless_os_pid(session) do
          nil -> nil
          pid -> %{headless_os_pid: pid}
        end

      nil ->
        nil
    end
  end

  defp headless_os_pid(%{metadata: %{claude_app_server_pid: pid}}) when is_binary(pid) do
    case Integer.parse(pid) do
      {n, _} -> n
      :error -> nil
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

  defp workspace_process_group_tracker(ownership) do
    fn process_group_id -> Ownership.track_process_group(ownership, process_group_id) end
  end

  defp workspace_provider_tracker(ownership) do
    fn provider -> Ownership.track_provider(ownership, provider) end
  end

  @doc false
  @spec run_session(Path.t(), Issue.t(), pid() | nil, keyword(), worker_host()) ::
          :ok | {:completed, Issue.t()} | {:error, term()}
  def run_session(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
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

    model = Keyword.fetch!(session_opts, :model)
    effort = Keyword.fetch!(session_opts, :effort)

    Logger.info("Resolved backend for #{Aiur.AgentRunner.issue_context(issue)} backend=#{session_backend} model=#{inspect(model)} effort=#{inspect(effort)} remote_control=#{rc?}")

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

    # Claim a provisional provider before opening a port or tmux pane. If this
    # runner dies in the tiny interval before backend metadata arrives, the
    # guardian remains fail-closed rather than replacing the live provider's
    # workspace underneath it.
    :ok = Ownership.expect_provider(Keyword.get(opts, :workspace_ownership))

    case start_agent_session(workspace, session_opts) do
      {:ok, session} ->
        :ok = Ownership.track_process_group(Keyword.get(opts, :workspace_ownership), process_group_id(session))
        :ok = Ownership.track_provider(Keyword.get(opts, :workspace_ownership), session_provider(session, worker_host))

        Lifecycle.record(issue.identifier, lifecycle_attempt_id, :agent_spinup, :end, %{
          operation_id: "session",
          backend: session_backend,
          outcome: :success
        })

        # Persist the live session handle so the next aiur restart can resume it.
        SessionResume.persist_session_handle(session, issue.identifier, worker_host)

        SessionResume.log_resume_outcome(issue, session, Keyword.get(session_opts, :resume_thread_id))

        report_repl_session(codex_update_recipient, issue, session)
        report_pause_containment(codex_update_recipient, issue, session)

        display_tailer = maybe_start_display_tailer(session, issue, rc?)

        # A resumed thread already carries the original task + full prior turn
        # history, so its first turn must continue rather than replay the
        # heavyweight cold-start prompt — mirroring the in-process turn N+1 flow.
        opts = Keyword.put(opts, :resumed, SessionResume.session_resumed?(session))

        try do
          TurnLoop.run_turns(
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
          stop_display_tailer(display_tailer)
          CodingAgent.stop_session(session)
        end

      {:error, reason} = error ->
        Lifecycle.record(issue.identifier, lifecycle_attempt_id, :agent_spinup, :end, %{
          operation_id: "session",
          backend: session_backend,
          outcome: :failed,
          reason_class: Lifecycle.reason_class(reason)
        })

        error
    end
  end

  defp session_provider(session, worker_host) do
    metadata = Map.get(session, :metadata, %{})

    %{}
    |> maybe_put_provider_pid(metadata[:codex_app_server_pid] || metadata[:claude_app_server_pid])
    |> maybe_put_provider_pid(Map.get(session, :os_pid))
    |> maybe_put_provider_group(process_group_id(session))
    |> maybe_put_remote_provider(worker_host)
  end

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

  @doc false
  @spec resolve_session_options(Issue.t(), keyword(), worker_host()) ::
          {String.t(), boolean(), keyword()}
  def resolve_session_options(issue, opts, worker_host) do
    backend = CodingAgent.backend_for(issue)
    model = CodingAgent.model_for(issue)
    effort = CodingAgent.effort_for(issue)

    rc? =
      (CodingAgent.remote_control_forced?(issue) or CodingAgent.routing_remote?(issue) or
         Config.agent_remote_control?()) and CodingAgent.remote_control?(backend)

    session_backend = remote_session_backend(backend, rc?)

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
  defp maybe_start_display_tailer(session, issue, rc?) do
    backend = session_backend(session)

    if should_display_tail?(backend, rc?, issue.identifier) do
      identifier = issue.identifier

      # DISPLAY-ONLY: broadcast straight to the opencode pane's transcript
      # topic. Do NOT route through codex_message_handler — that also does
      # per-record AgentEventLog.write (disk) and send_codex_update (to the
      # shared run recipient), so a `from: :start` backfill burst would hammer
      # both. The pane render only needs the transcript broadcast.
      on_message = fn
        %{transcript_event: event} -> AgentPubSub.broadcast_transcript(identifier, event)
        _ -> :ok
      end

      case DisplayTailer.start(
             identifier: identifier,
             on_message: on_message,
             owner: self()
           ) do
        {:ok, pid} ->
          pid

        {:error, reason} ->
          Logger.warning("display_tailer start_failed issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")
          nil
      end
    else
      nil
    end
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

    fallback_opts = opts |> Keyword.put(:backend, fallback) |> Keyword.delete(:remote_control)
    adapter_opts = Keyword.delete(fallback_opts, :attempt_id)

    case start_fun.(workspace, adapter_opts) do
      {:ok, session} -> {:ok, tag_session(session, fallback, fallback_opts)}
      {:error, _} = error -> error
    end
  end

  defp tag_session(session, backend, opts) do
    session
    |> Map.put(:backend, backend)
    |> maybe_put_attempt_id(Keyword.get(opts, :attempt_id))
  end

  defp maybe_put_attempt_id(session, attempt_id) when is_binary(attempt_id), do: Map.put(session, :attempt_id, attempt_id)
  defp maybe_put_attempt_id(session, _attempt_id), do: session

  @doc false
  @spec session_workspace(map()) :: Path.t() | nil
  def session_workspace(%{workspace: workspace}) when is_binary(workspace), do: workspace
  def session_workspace(_session), do: nil

  @doc false
  @spec session_worker_host(map()) :: worker_host()
  def session_worker_host(%{worker_host: worker_host}), do: worker_host
  def session_worker_host(_session), do: nil

  @doc false
  @spec session_backend(map()) :: String.t()
  def session_backend(%{backend: backend}) when is_binary(backend), do: backend
  def session_backend(_session), do: Config.agent_kind()
end
