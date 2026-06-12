defmodule Aiur.Claude.ReplAgent do
  @moduledoc """
  Persistent interactive-REPL Claude backend implementing the CodingAgent
  behaviour.

  Where `Aiur.Claude.CodingAgent` spawns `claude --print` one-shot per turn
  over JSON-RPC stdio, this driver keeps ONE long-lived interactive `claude`
  process alive in a hidden tmux pane and drives it with `send-keys`. Because
  the process persists, it can be launched with `--remote-control` so the same
  agent is also drivable from the Claude app (phone / claude.ai/code) — both
  surfaces share one transcript. Turn output is read by tailing that transcript
  jsonl (see `Aiur.Claude.TranscriptTailer`), not by scraping the pane.

  This module owns the session lifecycle: spawn the pane, wait for the REPL to
  become ready, optionally attach Remote Control, resolve the transcript path
  (cwd + newest mtime — the interactive `/remote-control` path writes no
  `bridge-pointer.json`), and tear the pane + process down cleanly so no
  `claude` process is orphaned.
  """

  @behaviour Aiur.CodingAgent

  require Logger

  alias Aiur.Claude.Config
  alias Aiur.Claude.RemoteControl
  alias Aiur.Claude.TranscriptTailer
  alias Aiur.Tmux

  @ready_prompt "❯"
  @ready_poll_ms 200
  @ready_timeout_ms 15_000

  # REPL panes live in their own tmux window named `aiur-repl-<beam_os_pid>-<n>`.
  # Embedding the owning BEAM's os pid lets the boot reaper kill only panes
  # whose owner is dead (never a side-by-side aiur instance's live panes) and
  # lets the shutdown sweep kill only this instance's own panes.
  @repl_window_prefix "aiur-repl-"

  # How often `run_turn` drains the transcript tailer and checks pane
  # liveness while a turn is in flight.
  @turn_poll_ms 250

  # After a pause request interrupts the live turn (Ctrl+C to the pane), how
  # long to wait for the tailer to observe the turn closing before parking
  # the agent as paused anyway. Expiry parks rather than errors: returning
  # `{:error, :turn_timeout}` would book a failed turn and possibly
  # re-dispatch, and looping forever would hang the pause.
  @pause_confirm_ms 10_000

  # Cold start: claude writes no session jsonl until the first user message
  # is submitted, so the first turn sends the prompt, then waits for the file
  # to materialize before tailing it.
  @transcript_wait_ms 15_000
  @transcript_poll_ms 100

  # The REPL renders its prompt glyph (`@ready_prompt`) before it actually
  # accepts input — and a `--remote-control` session lags further while it
  # connects — so the first paste is routinely dropped. Delivery is only safe
  # once the prompt lands in the input buffer, so we keep re-pasting (clearing
  # the line first) on `@echo_retype_ms` until the buffer confirms it or
  # `@echo_confirm_ms` elapses; only then does Enter submit. Without this,
  # Enter submits a blank line and the turn silently does nothing, the
  # transcript never appears, and the run fails `:no_transcript`.
  @echo_confirm_ms 20_000
  @echo_retype_ms 1_500
  @echo_poll_ms 100

  # A multi-line prompt is delivered as a bracketed paste, which the REPL
  # renders as a collapsed `[Pasted text +N lines]` chip rather than echoing
  # the literal text — so the buffer-landed check matches this chip as well as
  # a verbatim prefix (short single-line prompts still echo literally).
  @paste_indicator "[Pasted text"

  # When launched with `--remote-control`, the REPL prints a
  # `… https://claude.ai/code/session_… ` banner to the pane as it attaches,
  # alongside the ready prompt. Scan the pane for it once the REPL is ready;
  # it is a capability token surfaced only to the operator display, never
  # logged. The banner is also the proof RC attached: an account without RC
  # entitlement never prints it, so its absence within this budget is taken
  # as RC-unavailable and degrades the session to the non-RC backend (see
  # `build_ready_session/3`). The window is generous so a slow-but-working
  # attach is never mistaken for an unavailable one.
  @url_capture_timeout_ms 10_000
  @url_poll_ms 150

  @type session :: %{
          backend: String.t(),
          pane_id: String.t(),
          os_pid: integer() | nil,
          workspace: Path.t(),
          transcript_path: Path.t() | nil,
          projects_dir: Path.t() | nil,
          started_at: integer(),
          model: String.t() | nil,
          remote_control: boolean(),
          rc_name: String.t() | nil,
          session_url: String.t() | nil,
          tmux: GenServer.server()
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) when is_binary(workspace) do
    tmux = Keyword.get(opts, :tmux, Tmux)
    expanded = Path.expand(workspace)
    model = Keyword.get(opts, :model) || Config.model()
    rc? = Keyword.get(opts, :remote_control, false)
    repl_name = default_repl_name()
    rc_name = Keyword.get(opts, :rc_name) || repl_name
    window_name = Keyword.get(opts, :window_name) || repl_name

    # Captured before spawn so per-turn resolution can ignore any stale
    # transcript left by a prior run on this same workspace — claude writes
    # the live session's jsonl only at first-message time, always after this.
    started_at = System.os_time(:second)

    command = build_command(expanded, model, rc?, rc_name)

    Aiur.Perf.event(:repl_agent_spawn, workspace: expanded, remote_control: rc?)

    ctx = %{
      tmux: tmux,
      workspace: expanded,
      model: model,
      rc?: rc?,
      rc_name: rc_name,
      started_at: started_at,
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
        Aiur.ProcessReaper.register(:agent, {:pane, pane_id})
        Aiur.ProcessReaper.register(:agent, {:os_pid, os_pid}, comm: "claude")

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
    case capture_session_url(ctx.tmux, pane_id, ctx.opts) do
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
      tmux: ctx.tmux
    }
  end

  # Scan the just-ready pane for the Remote Control session URL. Polls until
  # the banner lands or the budget elapses — it can appear a beat after the
  # prompt. Returns nil when it never appears; for an RC session that nil is
  # the RC-unavailable signal (see `build_ready_session/3`).
  defp capture_session_url(tmux, pane_id, opts) do
    timeout = Keyword.get(opts, :url_capture_timeout_ms, @url_capture_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_capture_session_url(tmux, pane_id, deadline)
  end

  defp do_capture_session_url(tmux, pane_id, deadline) do
    url =
      case Tmux.capture_pane(tmux, pane_id) do
        {:ok, lines} -> lines |> Enum.join("\n") |> RemoteControl.parse_session_url()
        _ -> nil
      end

    cond do
      is_binary(url) ->
        url

      System.monotonic_time(:millisecond) >= deadline ->
        nil

      true ->
        Process.sleep(@url_poll_ms)
        do_capture_session_url(tmux, pane_id, deadline)
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{tmux: tmux, pane_id: pane_id} = session) do
    os_pid = Map.get(session, :os_pid)

    Aiur.ProcessReaper.unregister({:pane, pane_id})
    Aiur.ProcessReaper.unregister({:os_pid, os_pid})

    Tmux.kill_pane(tmux, pane_id)
    RemoteControl.graceful_kill_tree(os_pid)

    pane_gone? = not match?({:ok, _}, Tmux.pane_pid(tmux, pane_id))
    pid_gone? = os_pid_gone?(os_pid)

    Aiur.Perf.event(:repl_agent_teardown,
      workspace: Map.get(session, :workspace),
      pane_id: pane_id,
      os_pid: os_pid,
      pane_gone: pane_gone?,
      pid_gone: pid_gone?
    )

    :ok
  end

  def stop_session(_session), do: :ok

  @doc """
  Kill orphaned REPL panes left by a crashed or hard-killed aiur instance.

  REPL window names embed the owning BEAM's os pid; this kills only panes
  whose owner pid is no longer alive, so a side-by-side aiur instance's live
  panes are never touched. Called at boot alongside
  `Aiur.Claude.RemoteControl.reap_orphaned_servers/0`.
  """
  @spec reap_orphaned_panes(GenServer.server()) :: :ok
  def reap_orphaned_panes(tmux \\ Tmux) do
    sweep_repl_panes(tmux, fn owner_pid -> not os_pid_alive?(owner_pid) end)
  end

  @doc """
  Kill this instance's own REPL panes on graceful shutdown.

  The supervisor brutally kills the runner tasks, skipping their `after
  stop_session` cleanup, so without this sweep a graceful shutdown leaks
  every live REPL pane + `claude` process. Matches only windows owned by
  this BEAM's os pid so a side-by-side aiur instance is never touched.
  """
  @spec sweep_own_panes(GenServer.server()) :: :ok
  def sweep_own_panes(tmux \\ Tmux) do
    self_pid = beam_os_pid()
    sweep_repl_panes(tmux, fn owner_pid -> owner_pid == self_pid end)
  end

  defp sweep_repl_panes(tmux, owner_match?) do
    case Tmux.list_windows(tmux) do
      {:ok, windows} ->
        windows
        |> Enum.filter(fn {name, _pane} -> String.starts_with?(name, @repl_window_prefix) end)
        |> Enum.each(fn {name, pane_id} -> maybe_kill_repl_pane(tmux, name, pane_id, owner_match?) end)

        :ok

      _ ->
        :ok
    end
  end

  defp maybe_kill_repl_pane(tmux, name, pane_id, owner_match?) do
    with {:ok, owner_pid} <- parse_owner_pid(name),
         true <- owner_match?.(owner_pid) do
      kill_orphan_pane(tmux, pane_id)
    else
      _ -> :ok
    end
  end

  defp kill_orphan_pane(tmux, pane_id) do
    os_pid =
      case Tmux.pane_pid(tmux, pane_id) do
        {:ok, pid} -> pid
        _ -> nil
      end

    Tmux.kill_pane(tmux, pane_id)
    RemoteControl.graceful_kill_tree(os_pid)
    :ok
  end

  defp default_repl_name, do: "#{@repl_window_prefix}#{beam_os_pid()}-#{System.unique_integer([:positive])}"

  defp beam_os_pid, do: List.to_string(:os.getpid())

  # "aiur-repl-<owner_pid>-<n>" -> {:ok, "<owner_pid>"}; anything else :error.
  defp parse_owner_pid(window_name) do
    case Regex.run(~r/^aiur-repl-(\d+)-\d+/, window_name) do
      [_, owner_pid] -> {:ok, owner_pid}
      _ -> :error
    end
  end

  defp os_pid_alive?(pid) when is_binary(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  rescue
    _ -> true
  end

  defp os_pid_gone?(nil), do: true

  defp os_pid_gone?(pid) when is_integer(pid) do
    not match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
  rescue
    _ -> true
  end

  @spec normalize_event(map()) :: map()
  def normalize_event(event) when is_map(event) do
    # Usage / rate-limit normalization is identical to the headless backend.
    Aiur.Claude.CodingAgent.normalize_event(event)
  end

  @doc """
  Drive one turn over the persistent REPL.

  Sends `prompt` to the live pane (`paste_text` + `Enter`), tails the
  shared transcript for this turn's output (forwarding each extracted
  `transcript_event` to `on_message`), and blocks until the agent's terminal
  `stop_reason` lands or a backstop fires:

    * `{:ok, %{result, session_id, thread_id, turn_id}}` on completion
    * `{:error, :empty_prompt}` if the prompt is blank (no keys sent)
    * `{:error, :no_transcript}` if a cold-start turn's jsonl never appeared
    * `{:error, :turn_timeout}` if no completion arrives within the backstop;
      the session stays usable for the next turn
    * `{:error, :repl_gone}` if the pane dies mid-turn

  On a warm turn the tailer opens `from: :end` so it captures only this
  turn's newly-appended records. On a cold-start turn (no jsonl yet) the
  prompt is sent first so claude creates the file, then the tailer opens
  `from: :start` to pick up records written before it attached. Either way
  the tailer never replays prior history as input to the agent.
  """
  @spec run_turn(session(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:paused, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ [])

  def run_turn(_session, prompt, _issue, _opts) when not is_binary(prompt),
    do: {:error, :empty_prompt}

  def run_turn(%{} = session, prompt, _issue, opts) do
    if String.trim(prompt) == "" do
      {:error, :empty_prompt}
    else
      drive_turn(session, prompt, opts)
    end
  end

  defp drive_turn(session, prompt, opts) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    on_operator = Keyword.get(opts, :on_operator_message, fn -> :noop end)
    poll_ms = Keyword.get(opts, :poll_interval_ms, @turn_poll_ms)
    timeout_ms = Keyword.get(opts, :turn_timeout_ms) || Aiur.Config.agent_turn_timeout_ms()
    pause_confirm_ms = Keyword.get(opts, :pause_confirm_ms, @pause_confirm_ms)

    case prepare_turn(session, prompt, opts) do
      {:ok, transcript_path, from, prompt_sent?} ->
        session = %{session | transcript_path: transcript_path}
        {thread_id, turn_id} = turn_ids(transcript_path)
        session_id = "#{thread_id}-#{turn_id}"

        emit(on_message, :session_started, %{
          session_id: session_id,
          thread_id: thread_id,
          turn_id: turn_id
        })

        {:ok, tailer} = start_turn_tailer(session, turn_id, from, on_message)

        # Warm turns send AFTER the tailer attaches so no record is missed;
        # cold turns already sent the prompt to create the transcript.
        send_result = if prompt_sent?, do: :ok, else: send_prompt(session, prompt, opts)

        case send_result do
          :ok ->
            deadline = System.monotonic_time(:millisecond) + timeout_ms
            result = await_turn(session, tailer, turn_id, deadline, poll_ms, on_operator, pause_confirm_ms)
            stop_tailer(tailer)
            finish_turn(result, on_message, session_id, thread_id, turn_id)

          {:error, reason} ->
            stop_tailer(tailer)
            emit(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason})
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_turn(:ok, on_message, session_id, thread_id, turn_id) do
    emit(on_message, :turn_completed, %{session_id: session_id, turn_id: turn_id})

    {:ok, %{result: :completed, session_id: session_id, thread_id: thread_id, turn_id: turn_id}}
  end

  # A pause request interrupted this turn. The runner's `{:paused, _}` branch
  # reads `payload[:session_id]` for its log line, then restores the queue and
  # parks in its paused wait loop — so the payload must carry the ids.
  defp finish_turn({:paused, payload}, on_message, session_id, thread_id, turn_id) do
    emit(on_message, :turn_paused, %{session_id: session_id, turn_id: turn_id})

    {:paused,
     payload
     |> Map.put(:session_id, session_id)
     |> Map.put(:thread_id, thread_id)
     |> Map.put(:turn_id, turn_id)}
  end

  defp finish_turn({:error, reason}, on_message, session_id, _thread_id, _turn_id) do
    emit(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason})
    {:error, reason}
  end

  # Resolve the transcript for THIS turn and decide how to tail it.
  #
  # The orchestrator re-threads the original (possibly nil-transcript)
  # session each turn, so we re-resolve from the workspace every time.
  #
  #   * WARM — the jsonl already exists: tail `from: :end` (this turn only),
  #     and let the caller send the prompt after the tailer attaches.
  #   * COLD — no jsonl yet: send the prompt first so claude creates the
  #     file, wait for it to appear, then tail `from: :start` to pick up the
  #     records written before the tailer attached.
  defp prepare_turn(session, prompt, opts) do
    resolved = session.transcript_path || resolve_session_transcript(session)

    if is_binary(resolved) and File.exists?(resolved) do
      {:ok, resolved, :end, false}
    else
      with :ok <- send_prompt(session, prompt, opts),
           {:ok, path} <- await_transcript(session) do
        {:ok, path, :start, true}
      end
    end
  end

  # Resolve THIS session's transcript, ignoring any file older than spawn so
  # a re-run on a reused workspace never tails the prior session's jsonl.
  defp resolve_session_transcript(session) do
    RemoteControl.resolve_transcript_path(
      workspace: session.workspace,
      projects_dir: Map.get(session, :projects_dir),
      since: Map.get(session, :started_at, 0)
    )
  end

  # Only submit (Enter) once the typed prompt has actually echoed into the
  # input buffer; a dropped send must never be committed as a blank line.
  defp send_prompt(session, prompt, opts) do
    case confirm_typed(session, prompt, opts) do
      :ok -> Tmux.send_enter(session.tmux, session.pane_id)
      {:error, reason} -> {:error, reason}
    end
  end

  # Paste the prompt, then poll the input buffer until it lands. The REPL
  # renders its glyph before it accepts input (and an RC session lags
  # further), so the first paste is routinely dropped — keep clearing the line
  # and re-pasting on `retype_ms` until the buffer reflects it. Fail loudly
  # with `:prompt_not_delivered` if the budget elapses with nothing landed,
  # rather than submitting a blank line. Reads the pane only to confirm input
  # (not output).
  defp confirm_typed(session, prompt, opts) do
    confirm_ms = Keyword.get(opts, :prompt_confirm_ms, @echo_confirm_ms)
    retype_ms = Keyword.get(opts, :prompt_retype_ms, @echo_retype_ms)
    prefix = echo_prefix(prompt)
    Tmux.paste_text(session.tmux, session.pane_id, prompt)
    now = System.monotonic_time(:millisecond)
    poll_echo(session, prompt, prefix, confirm_ms, retype_ms, now, now)
  end

  defp poll_echo(session, prompt, prefix, confirm_ms, retype_ms, start, last_retype) do
    elapsed = System.monotonic_time(:millisecond) - start

    cond do
      input_echoes?(session, prefix) ->
        :ok

      elapsed >= confirm_ms ->
        {:error, :prompt_not_delivered}

      System.monotonic_time(:millisecond) - last_retype >= retype_ms ->
        # The paste was dropped (glyph showed before the REPL was live);
        # clear any partial buffer and re-paste now that it may be ready.
        Tmux.clear_input(session.tmux, session.pane_id)
        Tmux.paste_text(session.tmux, session.pane_id, prompt)
        Process.sleep(@echo_poll_ms)
        now = System.monotonic_time(:millisecond)
        poll_echo(session, prompt, prefix, confirm_ms, retype_ms, start, now)

      true ->
        Process.sleep(@echo_poll_ms)
        poll_echo(session, prompt, prefix, confirm_ms, retype_ms, start, last_retype)
    end
  end

  defp input_echoes?(session, prefix) do
    case Tmux.capture_pane(session.tmux, session.pane_id) do
      {:ok, lines} ->
        joined = Enum.join(lines, "\n")
        String.contains?(joined, prefix) or String.contains?(joined, @paste_indicator)

      _ ->
        false
    end
  end

  defp echo_prefix(prompt) do
    prompt |> String.trim() |> String.slice(0, 24)
  end

  # Poll for the session jsonl to materialize after a cold-start prompt.
  defp await_transcript(session) do
    deadline = System.monotonic_time(:millisecond) + @transcript_wait_ms
    await_transcript(session, deadline)
  end

  defp await_transcript(session, deadline) do
    path = resolve_session_transcript(session)

    cond do
      is_binary(path) and File.exists?(path) ->
        {:ok, path}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :no_transcript}

      true ->
        Process.sleep(@transcript_poll_ms)
        await_transcript(session, deadline)
    end
  end

  # The tailer fires `on_turn_end` from its own process; route that back to
  # this run_turn process so the await loop can unblock. Each transcript
  # event is wrapped so the orchestrator's transcript dispatch passes it
  # through unchanged (see `Aiur.Claude.Transcript.extract/2`).
  defp start_turn_tailer(session, turn_id, from, on_message) do
    parent = self()

    TranscriptTailer.start_link(
      path: session.transcript_path,
      from: from,
      turn_id: turn_id,
      interval_ms: nil,
      on_message: fn event ->
        emit_transcript(on_message, event)
      end,
      on_turn_end: fn reason ->
        send(parent, {:turn_end, turn_id, reason})
      end
    )
  end

  defp await_turn(session, tailer, turn_id, deadline, poll_ms, on_operator, pause_confirm_ms) do
    cond do
      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :turn_timeout}

      not pane_alive?(session) ->
        {:error, :repl_gone}

      true ->
        TranscriptTailer.poll(tailer)

        receive do
          {:turn_end, ^turn_id, _reason} ->
            :ok

          # An operator message landed mid-turn. The REPL accepts input
          # while the agent works, so claim it and type it straight into
          # the live pane rather than holding it for a checkpoint.
          {:agent_queue_updated, _identifier, _item_id, true} ->
            deliver_immediate_operator_message(session, on_operator)
            await_turn(session, tailer, turn_id, deadline, poll_ms, on_operator, pause_confirm_ms)

          {:agent_queue_updated, _identifier, _item_id, _deliver_now} ->
            await_turn(session, tailer, turn_id, deadline, poll_ms, on_operator, pause_confirm_ms)

          {:agent_queue_updated, _identifier, _item_id} ->
            await_turn(session, tailer, turn_id, deadline, poll_ms, on_operator, pause_confirm_ms)

          # A pause request landed mid-turn. Interrupt the live REPL turn
          # (Ctrl+C to the pane — same primitive as the queue-drain
          # `:interrupt` path), wait briefly for the tailer to observe the
          # turn closing, and park as paused. A failed interrupt send still
          # parks: the operator asked for a pause, and erroring out would
          # book a failed turn instead.
          {:pause_agent, request_id} when is_integer(request_id) ->
            case interrupt(session) do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.warning("repl_pause interrupt_failed turn_id=#{turn_id} reason=#{inspect(reason)}")
            end

            confirm_deadline = System.monotonic_time(:millisecond) + pause_confirm_ms
            await_pause_confirm(tailer, turn_id, confirm_deadline, poll_ms)
            {:paused, %{request_id: request_id}}
        after
          0 ->
            Process.sleep(poll_ms)
            await_turn(session, tailer, turn_id, deadline, poll_ms, on_operator, pause_confirm_ms)
        end
    end
  end

  # Wait for the interrupted turn to close in the transcript so the session
  # is quiescent before the runner parks. Expiry logs and parks anyway —
  # never an error, never an infinite loop (see @pause_confirm_ms).
  defp await_pause_confirm(tailer, turn_id, deadline, poll_ms) do
    cond do
      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning("repl_pause pause_confirm_timeout turn_id=#{turn_id}")
        :timeout

      true ->
        TranscriptTailer.poll(tailer)

        receive do
          {:turn_end, ^turn_id, _reason} -> :ok
        after
          0 ->
            Process.sleep(poll_ms)
            await_pause_confirm(tailer, turn_id, deadline, poll_ms)
        end
    end
  end

  # The claim callback (supplied by the runner) talks to the orchestrator
  # queue and hands back the operator text plus consume/restore callbacks,
  # so the driver stays decoupled from the queue store. `:noop` means
  # nothing was claimable (e.g. a racing drain already took it).
  defp deliver_immediate_operator_message(session, on_operator) do
    case on_operator.() do
      {:deliver_text, text, on_success, on_failure}
      when is_binary(text) and is_function(on_success, 1) and is_function(on_failure, 1) ->
        case send_operator_message(session, %{kind: :text, body: text}) do
          {:ok, request_id} -> on_success.(%{request_id: request_id})
          {:error, reason} -> on_failure.(reason)
        end

      :noop ->
        :ok
    end
  end

  defp pane_alive?(%{tmux: tmux, pane_id: pane_id}) do
    match?({:ok, _}, Tmux.pane_pid(tmux, pane_id))
  end

  defp stop_tailer(tailer) do
    if Process.alive?(tailer), do: GenServer.stop(tailer, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  # Thread id is the transcript file's UUID (stable for the life of the
  # persistent session); the turn id appends a per-turn counter since the
  # REPL has no JSON-RPC `turn.id`.
  defp turn_ids(transcript_path) do
    uuid = transcript_path |> Path.basename() |> Path.rootname()
    counter = System.unique_integer([:positive, :monotonic])
    {uuid, "#{uuid}-#{counter}"}
  end

  defp emit(on_message, event, details) do
    on_message.(Map.merge(details, %{event: event, timestamp: DateTime.utc_now()}))
  end

  defp emit_transcript(on_message, event) do
    on_message.(%{event: :transcript, transcript_event: event, timestamp: DateTime.utc_now()})
  end

  @doc """
  Inject an operator message straight into the live REPL pane.

  This is the whole of mid-turn delivery: sanitize the text, type it with
  `send_keys_literal`, then submit with one `Enter`. The agent's native
  input queue does the rest — it folds the message in at the next natural
  boundary without aborting in-flight work, so there is no bespoke
  interrupt-then-send path here (cutting the agent off is a separate,
  explicit parity action, not this one).

  Operator text is typed verbatim into a PTY, so it is sanitized first:
  every control byte (newlines that would submit early, `Esc`/C0/C1
  sequences that would trip the REPL's own keybindings) is collapsed to a
  space. The single trailing `Enter` is the only submit.
  """
  @spec send_operator_message(session(), Aiur.CodingAgent.operator_payload()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(%{tmux: tmux, pane_id: pane_id}, %{kind: :text, body: body})
      when is_binary(body) do
    case sanitize_pane_input(body) do
      "" ->
        {:error, :empty_message}

      text ->
        with :ok <- Tmux.send_keys_literal(tmux, pane_id, text),
             :ok <- Tmux.send_enter(tmux, pane_id) do
          {:ok, System.unique_integer([:positive])}
        end
    end
  end

  def send_operator_message(_session, _payload), do: {:error, :invalid_message}

  @doc """
  Interrupt the REPL's current turn by sending `Ctrl+C` to its pane.

  This is the explicit operator-interrupt path: unlike
  `send_operator_message/2`, which lets Claude's native queue fold a
  message in at the next boundary without aborting in-flight work, this
  cuts the active turn at Claude's next safe point so a queued message is
  drained immediately.
  """
  @spec interrupt(session()) :: :ok | {:error, term()}
  def interrupt(%{tmux: tmux, pane_id: pane_id}) when is_binary(pane_id) do
    Tmux.send_interrupt(tmux, pane_id)
  end

  def interrupt(_session), do: {:error, :invalid_session}

  # Operator content is typed into a live PTY via `send-keys -l`, which
  # emits the bytes verbatim. Collapse every control byte to a space so a
  # crafted message cannot submit early (embedded newline), abort the agent
  # (`Esc`), or inject terminal escape codes / extra keystrokes. The one
  # explicit `Enter` in send_operator_message/2 is the only submit.
  defp sanitize_pane_input(body) do
    body
    |> String.replace(~r/[\x00-\x1f\x7f]/, " ")
    |> String.replace(~r/ {2,}/, " ")
    |> String.trim()
  end

  # ------------------------------------------------------------------ internals

  # `exec` replaces the wrapping shell so the pane's top process IS `claude`,
  # which makes `pane_pid` the process graceful_kill must terminate.
  defp build_command(workspace, model, rc?, rc_name) do
    flags =
      ["claude"]
      |> append_if(rc?, ["--remote-control", shell_escape(rc_name)])
      |> Kernel.++(["--permission-mode", shell_escape(Config.permission_mode())])
      |> append_if(is_binary(model), ["--model", shell_escape(model || "")])
      |> Enum.join(" ")

    "cd #{shell_escape(workspace)} && exec #{flags}"
  end

  defp append_if(list, true, extra), do: list ++ extra
  defp append_if(list, false, _extra), do: list
  defp append_if(list, nil, _extra), do: list

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

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
