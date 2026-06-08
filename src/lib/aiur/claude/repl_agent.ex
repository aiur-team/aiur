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

  # How often `run_turn` drains the transcript tailer and checks pane
  # liveness while a turn is in flight.
  @turn_poll_ms 250

  @type session :: %{
          backend: String.t(),
          pane_id: String.t(),
          os_pid: integer() | nil,
          workspace: Path.t(),
          transcript_path: Path.t() | nil,
          model: String.t() | nil,
          remote_control: boolean(),
          rc_name: String.t() | nil,
          tmux: GenServer.server()
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) when is_binary(workspace) do
    tmux = Keyword.get(opts, :tmux, Tmux)
    expanded = Path.expand(workspace)
    model = Keyword.get(opts, :model) || Config.model()
    rc? = Keyword.get(opts, :remote_control, false)
    rc_name = Keyword.get(opts, :rc_name) || "aiur-repl-#{System.unique_integer([:positive])}"
    window_name = Keyword.get(opts, :window_name) || rc_name

    command = build_command(expanded, model, rc?, rc_name)

    Aiur.Perf.event(:repl_agent_spawn, workspace: expanded, remote_control: rc?)

    case Tmux.new_hidden_window(tmux, window_name, command) do
      {:ok, pane_id} ->
        finish_start(tmux, pane_id, expanded, model, rc?, rc_name, opts)

      {:error, _reason} = err ->
        err
    end
  end

  defp finish_start(tmux, pane_id, expanded, model, rc?, rc_name, opts) do
    timeout = Keyword.get(opts, :ready_timeout_ms, @ready_timeout_ms)

    case await_ready(tmux, pane_id, timeout) do
      :ok ->
        os_pid =
          case Tmux.pane_pid(tmux, pane_id) do
            {:ok, pid} -> pid
            _ -> nil
          end

        transcript_path =
          RemoteControl.resolve_transcript_path(
            workspace: expanded,
            projects_dir: Keyword.get(opts, :projects_dir)
          )

        Aiur.Perf.event(:repl_agent_ready,
          workspace: expanded,
          pane_id: pane_id,
          os_pid: os_pid,
          remote_control: rc?
        )

        {:ok,
         %{
           backend: "claude-repl",
           pane_id: pane_id,
           os_pid: os_pid,
           workspace: expanded,
           transcript_path: transcript_path,
           model: model,
           remote_control: rc?,
           rc_name: rc_name,
           tmux: tmux
         }}

      {:error, :repl_not_ready} = err ->
        # Readiness failed but the pane exists — kill it so nothing leaks.
        Tmux.kill_pane(tmux, pane_id)
        err
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{tmux: tmux, pane_id: pane_id} = session) do
    Tmux.kill_pane(tmux, pane_id)
    RemoteControl.graceful_kill(Map.get(session, :os_pid))

    Aiur.Perf.event(:repl_agent_teardown,
      workspace: Map.get(session, :workspace),
      pane_id: pane_id,
      os_pid: Map.get(session, :os_pid)
    )

    :ok
  end

  def stop_session(_session), do: :ok

  @spec normalize_event(map()) :: map()
  def normalize_event(event) when is_map(event) do
    # Usage / rate-limit normalization is identical to the headless backend.
    Aiur.Claude.CodingAgent.normalize_event(event)
  end

  @doc """
  Drive one turn over the persistent REPL.

  Sends `prompt` to the live pane (`send_keys_literal` + `Enter`), tails the
  shared transcript for this turn's output (forwarding each extracted
  `transcript_event` to `on_message`), and blocks until the agent's terminal
  `stop_reason` lands or a backstop fires:

    * `{:ok, %{result, session_id, thread_id, turn_id}}` on completion
    * `{:error, :empty_prompt}` if the prompt is blank (no keys sent)
    * `{:error, :no_transcript}` if the session never resolved a transcript path
    * `{:error, :turn_timeout}` if no completion arrives within the backstop;
      the session stays usable for the next turn
    * `{:error, :repl_gone}` if the pane dies mid-turn

  The turn tailer is opened `from: :end` so it captures only this turn's
  newly-appended records — it never replays prior history as input.
  """
  @spec run_turn(session(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ [])

  def run_turn(_session, prompt, _issue, _opts) when not is_binary(prompt),
    do: {:error, :empty_prompt}

  def run_turn(%{transcript_path: nil}, _prompt, _issue, _opts),
    do: {:error, :no_transcript}

  def run_turn(%{} = session, prompt, _issue, opts) do
    if String.trim(prompt) == "" do
      {:error, :empty_prompt}
    else
      drive_turn(session, prompt, opts)
    end
  end

  defp drive_turn(session, prompt, opts) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    poll_ms = Keyword.get(opts, :poll_interval_ms, @turn_poll_ms)
    timeout_ms = Keyword.get(opts, :turn_timeout_ms) || Aiur.Config.agent_turn_timeout_ms()

    {thread_id, turn_id} = turn_ids(session.transcript_path)
    session_id = "#{thread_id}-#{turn_id}"

    emit(on_message, :session_started, %{
      session_id: session_id,
      thread_id: thread_id,
      turn_id: turn_id
    })

    {:ok, tailer} = start_turn_tailer(session, turn_id, on_message)

    Tmux.send_keys_literal(session.tmux, session.pane_id, prompt)
    Tmux.send_enter(session.tmux, session.pane_id)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    result = await_turn(session, tailer, turn_id, deadline, poll_ms)
    stop_tailer(tailer)

    case result do
      :ok ->
        emit(on_message, :turn_completed, %{session_id: session_id, turn_id: turn_id})
        {:ok, %{result: :completed, session_id: session_id, thread_id: thread_id, turn_id: turn_id}}

      {:error, reason} ->
        emit(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason})
        {:error, reason}
    end
  end

  # The tailer fires `on_turn_end` from its own process; route that back to
  # this run_turn process so the await loop can unblock. Each transcript
  # event is wrapped so the orchestrator's transcript dispatch passes it
  # through unchanged (see `Aiur.Claude.Transcript.extract/2`).
  defp start_turn_tailer(session, turn_id, on_message) do
    parent = self()

    TranscriptTailer.start_link(
      path: session.transcript_path,
      from: :end,
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

  defp await_turn(session, tailer, turn_id, deadline, poll_ms) do
    cond do
      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :turn_timeout}

      not pane_alive?(session) ->
        {:error, :repl_gone}

      true ->
        TranscriptTailer.poll(tailer)

        receive do
          {:turn_end, ^turn_id, _reason} -> :ok
        after
          0 ->
            Process.sleep(poll_ms)
            await_turn(session, tailer, turn_id, deadline, poll_ms)
        end
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
