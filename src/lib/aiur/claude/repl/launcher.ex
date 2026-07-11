defmodule Aiur.Claude.Repl.Launcher do
  @moduledoc """
  Session spawn and readiness: creates the tmux pane, waits for the REPL prompt
  glyph, registers with the ProcessReaper, optionally attaches Remote Control,
  and returns a fully-populated `Aiur.Claude.ReplAgent.session()`.
  """

  require Logger

  alias Aiur.Claude.Config
  alias Aiur.Claude.RemoteControl
  alias Aiur.Claude.Repl.Command
  alias Aiur.Claude.Repl.RcAttach
  alias Aiur.Claude.Repl.Reaper
  alias Aiur.Tmux

  @ready_prompt "❯"
  @ready_poll_ms 200
  @ready_timeout_ms 15_000

  @spec start_session(Path.t(), keyword()) :: {:ok, Aiur.Claude.ReplAgent.session()} | {:error, term()}
  def start_session(workspace, opts \\ []) when is_binary(workspace) do
    tmux = Keyword.get(opts, :tmux, Tmux)
    expanded = Path.expand(workspace)
    model = Keyword.get(opts, :model) || Config.model()
    effort = Keyword.get(opts, :effort)
    rc? = Keyword.get(opts, :remote_control, false)
    repl_name = Reaper.default_repl_name()
    rc_name = Keyword.get(opts, :rc_name) || repl_name
    window_name = Keyword.get(opts, :window_name) || repl_name

    # Captured before spawn so per-turn resolution can ignore any stale
    # transcript left by a prior run on this same workspace — claude writes
    # the live session's jsonl only at first-message time, always after this.
    started_at = System.os_time(:second)

    # RC sessions emit no structured stdout, so turn detection rides on claude
    # lifecycle hooks POSTed to the dashboard. Inject them via --settings (which
    # composes with the operator's own settings). Best-effort: a missing
    # identifier or unbound dashboard degrades to no hooks rather than failing.
    settings_path = Command.maybe_hook_settings(rc?, Keyword.get(opts, :identifier))

    # Resume the prior conversation across an aiur restart when the runner
    # handed us a persisted session id whose transcript still exists (#613).
    # nil means a clean start (no handle, or its transcript is gone).
    resume_id = Command.resume_session_id(opts, expanded)
    command = Command.build_command(expanded, model, effort, rc?, rc_name, settings_path, resume_id)

    Aiur.Perf.event(:repl_agent_spawn, workspace: expanded, remote_control: rc?, resumed: is_binary(resume_id))

    ctx = %{
      tmux: tmux,
      workspace: expanded,
      model: model,
      rc?: rc?,
      rc_name: rc_name,
      identifier: Keyword.get(opts, :identifier),
      hooks?: is_binary(settings_path),
      started_at: started_at,
      resume_id: resume_id,
      opts: opts
    }

    case Tmux.new_hidden_window(tmux, window_name, command) do
      {:ok, pane_id} ->
        finish_start(ctx, pane_id)

      {:error, _reason} = err ->
        err
    end
  end

  defp finish_start(%{tmux: tmux, opts: opts} = ctx, pane_id) do
    timeout = Keyword.get(opts, :ready_timeout_ms, @ready_timeout_ms)

    case await_ready(tmux, pane_id, timeout) do
      :ok ->
        os_pid =
          case Tmux.pane_pid(tmux, pane_id) do
            {:ok, pid} -> pid
            _ -> nil
          end

        Aiur.Perf.event(:repl_agent_ready,
          workspace: ctx.workspace,
          pane_id: pane_id,
          os_pid: os_pid,
          remote_control: ctx.rc?
        )

        # The pane runs `exec claude`, so the pane pid IS the REPL; register
        # both so shutdown reaps survive either teardown path going stale.
        actor_meta = [ticket: ctx.identifier, backend: "claude-repl", worker_host: nil, remote: false]
        Aiur.ProcessReaper.register(:agent, {:pane, pane_id}, actor_meta)
        Aiur.ProcessReaper.register(:agent, {:os_pid, os_pid}, [comm: "claude"] ++ actor_meta)

        build_ready_session(ctx, pane_id, os_pid)

      {:error, :repl_not_ready} = err ->
        # Readiness failed but the pane exists — kill it so nothing leaks.
        Tmux.kill_pane(tmux, pane_id)
        err
    end
  end

  # A `--remote-control` REPL only earns RC mode if it actually attaches: the
  # REPL prints a `https://claude.ai/code/session_…` banner once the cloud
  # session goes live. On an account without RC entitlement the banner never
  # appears (and every later `send-keys` would time out as
  # `:prompt_not_delivered`), so a missing banner means RC-unavailable. Tear
  # the pane down and return `:remote_control_unavailable` so the runner
  # degrades to the non-RC headless backend rather than stranding the issue.
  # A non-RC REPL skips this gate entirely.
  defp build_ready_session(%{rc?: true} = ctx, pane_id, os_pid) do
    case RcAttach.capture_session_url(ctx.tmux, pane_id, ctx.opts) do
      url when is_binary(url) ->
        {:ok, repl_session(ctx, pane_id, os_pid, url)}

      nil ->
        Tmux.kill_pane(ctx.tmux, pane_id)
        RemoteControl.graceful_kill_tree(os_pid)

        Aiur.Perf.event(:repl_agent_rc_unavailable, workspace: ctx.workspace, pane_id: pane_id)
        Logger.warning("claude-repl remote-control did not attach; degrading to non-RC backend")

        {:error, :remote_control_unavailable}
    end
  end

  defp build_ready_session(%{rc?: false} = ctx, pane_id, os_pid) do
    {:ok, repl_session(ctx, pane_id, os_pid, nil)}
  end

  defp repl_session(ctx, pane_id, os_pid, session_url) do
    resume_id = Map.get(ctx, :resume_id)

    %{
      backend: "claude-repl",
      pane_id: pane_id,
      os_pid: os_pid,
      workspace: ctx.workspace,
      transcript_path: nil,
      started_at: ctx.started_at,
      projects_dir: Keyword.get(ctx.opts, :projects_dir),
      model: ctx.model,
      remote_control: ctx.rc?,
      rc_name: ctx.rc_name,
      session_url: session_url,
      # A resumed spawn carries the prior session id (== transcript filename) so
      # the runner persists the right handle and serves the lightweight
      # continuation prompt; a clean start leaves both unset (the id is then
      # learned per-turn from the transcript). See `resume_session_id/2`.
      resumed: is_binary(resume_id),
      thread_id: resume_id,
      # Set only when lifecycle hooks were injected (see maybe_hook_settings/2);
      # its presence is what routes run_turn to hook-driven detection.
      identifier: if(Map.get(ctx, :hooks?, false), do: ctx.identifier, else: nil),
      tmux: ctx.tmux
    }
  end

  defp await_ready(tmux, pane_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_ready(tmux, pane_id, deadline)
  end

  defp do_await_ready(tmux, pane_id, deadline) do
    case Tmux.capture_pane(tmux, pane_id) do
      {:ok, lines} ->
        if Enum.any?(lines, &String.contains?(&1, @ready_prompt)) do
          :ok
        else
          retry_ready(tmux, pane_id, deadline)
        end

      {:error, _} ->
        retry_ready(tmux, pane_id, deadline)
    end
  end

  defp retry_ready(tmux, pane_id, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :repl_not_ready}
    else
      Process.sleep(@ready_poll_ms)
      do_await_ready(tmux, pane_id, deadline)
    end
  end
end
