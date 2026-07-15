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
  alias Aiur.{ProcessReaper, Tmux}

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

    ctx = %{
      tmux: tmux,
      workspace: expanded,
      model: model,
      effort: effort,
      rc?: rc?,
      rc_name: rc_name,
      window_name: window_name,
      started_at: started_at,
      opts: opts
    }

    # RC sessions emit no structured stdout, so turn detection rides on Claude
    # lifecycle hooks POSTed to Aiur.HttpServer. Never start RC without that
    # capability: model:remote tickets and live promotion can opt into RC after
    # application boot, beyond the launcher's static config compatibility check.
    settings_path =
      opts
      |> Keyword.get(:hook_settings_fun, &Command.maybe_hook_settings/2)
      |> then(& &1.(rc?, Keyword.get(opts, :identifier)))

    if rc? and not is_binary(settings_path) do
      Logger.error("claude-repl remote-control requires a bound Aiur.HttpServer lifecycle-hook listener")
      {:error, :remote_control_requires_dashboard}
    else
      do_start_session(ctx, settings_path)
    end
  end

  defp do_start_session(ctx, settings_path) do
    # Resume the prior conversation across an aiur restart when the runner
    # handed us a persisted session id whose transcript still exists (#613).
    # nil means a clean start (no handle, or its transcript is gone).
    resume_id = Command.resume_session_id(ctx.opts, ctx.workspace)

    command =
      Command.build_command(
        ctx.workspace,
        ctx.model,
        ctx.effort,
        ctx.rc?,
        ctx.rc_name,
        settings_path,
        resume_id
      )

    Aiur.Perf.event(:repl_agent_spawn,
      workspace: ctx.workspace,
      remote_control: ctx.rc?,
      resumed: is_binary(resume_id)
    )

    ctx =
      Map.merge(ctx, %{
        identifier: Keyword.get(ctx.opts, :identifier),
        process_reaper: Keyword.get(ctx.opts, :process_reaper, ProcessReaper),
        hooks?: is_binary(settings_path),
        resume_id: resume_id
      })

    case Tmux.new_hidden_window(ctx.tmux, ctx.window_name, command) do
      {:ok, pane_id} ->
        os_pid = pane_pid(ctx.tmux, pane_id)
        process_group_id = process_group(ctx, os_pid)
        process_group_identity = process_identity(ctx, os_pid)

        case notify_provider_started(ctx, os_pid, process_group_id) do
          :ok when is_integer(process_group_id) ->
            finish_start(ctx, pane_id, os_pid, process_group_id, process_group_identity)

          :ok ->
            cleanup_spawned_pane(
              ctx,
              pane_id,
              os_pid,
              process_group_id,
              process_group_identity,
              {:error, :repl_containment_unavailable}
            )

          {:error, _reason} = error ->
            cleanup_spawned_pane(ctx, pane_id, os_pid, process_group_id, process_group_identity, error)
        end

      {:error, _reason} = err ->
        err
    end
  end

  defp notify_provider_started(%{opts: opts}, os_pid, process_group_id) do
    callback = Keyword.get(opts, :on_provider_started, fn _provider -> :ok end)

    provider =
      if is_integer(os_pid) and os_pid > 0 do
        %{root_pid: os_pid, descendant_pids: RemoteControl.process_tree(os_pid)}
        |> maybe_put_process_group(process_group_id)
      else
        %{}
      end

    callback.(provider)
  end

  defp cleanup_spawned_pane(ctx, pane_id, os_pid, process_group_id, process_group_identity, error) do
    session = %{
      tmux: ctx.tmux,
      pane_id: pane_id,
      os_pid: os_pid,
      process_group_id: process_group_id,
      process_group_identity: process_group_identity,
      workspace: ctx.workspace
    }

    case Reaper.stop_session(session) do
      {:ok, :cleanup_proven} ->
        notify_provider_cleanup(ctx, :succeeded)
        error

      {:error, _reason} = cleanup_error ->
        notify_provider_cleanup(ctx, :unknown)
        cleanup_error
    end
  end

  defp notify_provider_cleanup(%{opts: opts}, outcome) do
    opts
    |> Keyword.get(:on_provider_cleanup, fn _outcome -> :ok end)
    |> then(& &1.(outcome))
  end

  defp process_group(%{opts: opts}, os_pid) do
    opts
    |> Keyword.get(:process_group_fun, &RemoteControl.process_group_for_pid/1)
    |> then(& &1.(os_pid))
  end

  defp process_identity(%{opts: opts}, os_pid) do
    result =
      opts
      |> Keyword.get(:process_identity_fun, &RemoteControl.process_identity/1)
      |> then(& &1.(os_pid))

    case result do
      {:ok, identity} -> {:known, identity}
      :gone -> :gone
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp maybe_put_process_group(provider, process_group_id)
       when is_integer(process_group_id) and process_group_id > 0,
       do: Map.put(provider, :process_group_id, process_group_id)

  defp maybe_put_process_group(provider, _process_group_id), do: provider

  defp pane_pid(tmux, pane_id) do
    case Tmux.pane_pid(tmux, pane_id) do
      {:ok, pid} -> pid
      _ -> nil
    end
  end

  defp finish_start(ctx, pane_id, os_pid, process_group_id, process_group_identity) do
    %{tmux: tmux, opts: opts} = ctx
    timeout = Keyword.get(opts, :ready_timeout_ms, @ready_timeout_ms)

    case await_ready(tmux, pane_id, timeout) do
      :ok ->
        Aiur.Perf.event(:repl_agent_ready,
          workspace: ctx.workspace,
          pane_id: pane_id,
          os_pid: os_pid,
          remote_control: ctx.rc?
        )

        # The pane runs `exec claude`, so the pane pid IS the REPL; register
        # both so shutdown reaps survive either teardown path going stale.
        actor_meta = [ticket: ctx.identifier, backend: "claude-repl", worker_host: nil, remote: false]
        ProcessReaper.register(ctx.process_reaper, :agent, {:pane, pane_id}, actor_meta)
        ProcessReaper.register(ctx.process_reaper, :agent, {:os_pid, os_pid}, [comm: "claude"] ++ actor_meta)

        build_ready_session(ctx, pane_id, os_pid, process_group_id, process_group_identity)

      {:error, :repl_not_ready} = err ->
        # Containment was registered as soon as the pane existed. Do not fall
        # back into the same workspace when tmux refuses its cleanup request:
        # the guardian must retain and reap that known root first.
        cleanup_spawned_pane(ctx, pane_id, os_pid, process_group_id, process_group_identity, err)
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
  defp build_ready_session(%{rc?: true} = ctx, pane_id, os_pid, process_group_id, process_group_identity) do
    case RcAttach.capture_session_url(ctx.tmux, pane_id, ctx.opts) do
      url when is_binary(url) ->
        {:ok, repl_session(ctx, pane_id, os_pid, process_group_id, process_group_identity, url)}

      nil ->
        case cleanup_spawned_pane(
               ctx,
               pane_id,
               os_pid,
               process_group_id,
               process_group_identity,
               {:error, :remote_control_unavailable}
             ) do
          {:error, :remote_control_unavailable} = error ->
            Aiur.Perf.event(:repl_agent_rc_unavailable, workspace: ctx.workspace, pane_id: pane_id)
            Logger.warning("claude-repl remote-control did not attach; degrading to non-RC backend")
            error

          {:error, {:repl_cleanup_failed, _reason}} = cleanup_error ->
            cleanup_error
        end
    end
  end

  defp build_ready_session(%{rc?: false} = ctx, pane_id, os_pid, process_group_id, process_group_identity) do
    {:ok, repl_session(ctx, pane_id, os_pid, process_group_id, process_group_identity, nil)}
  end

  defp repl_session(ctx, pane_id, os_pid, process_group_id, process_group_identity, session_url) do
    resume_id = Map.get(ctx, :resume_id)

    %{
      backend: "claude-repl",
      pane_id: pane_id,
      os_pid: os_pid,
      process_group_id: process_group_id,
      process_group_identity: process_group_identity,
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
