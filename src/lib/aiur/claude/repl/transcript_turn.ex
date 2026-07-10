defmodule Aiur.Claude.Repl.TranscriptTurn do
  @moduledoc """
  Transcript-tailing (non-RC) turn loop.

  Runs in the caller's process as a plain function call — no Task, no GenServer.
  The warm/cold ordering invariant is load-bearing:

  * Warm: tailer attaches `from: :end`, prompt sent AFTER attach.
  * Cold: prompt sent first (claude creates the file), tailer `from: :start`.

  Reordering either loses this turn's records or replays history; backfill stays
  display-only, the tailer never re-prompts the agent.
  """

  require Logger

  alias Aiur.Claude.RemoteControl
  alias Aiur.Claude.Repl.OperatorInject
  alias Aiur.Claude.Repl.PromptSubmit
  alias Aiur.Claude.Repl.Reaper
  alias Aiur.Claude.Repl.TurnEvents
  alias Aiur.Claude.TranscriptTailer

  # Deliberately duplicated from HookTurn — do not create a shared constants module.
  @turn_poll_ms 250
  # Expiry parks rather than errors (never {:error, :turn_timeout} on pause path).
  @pause_confirm_ms 10_000
  # Cold start: claude writes no session jsonl until first message.
  @transcript_wait_ms 15_000
  @transcript_poll_ms 100

  @doc """
  Drive one transcript-tailing (non-RC) turn. See `Aiur.Claude.ReplAgent.run_turn/4`
  for the full warm/cold semantics and return shape.
  """
  @spec run(map(), String.t(), keyword()) :: {:ok, map()} | {:paused, map()} | {:error, term()}
  def run(session, prompt, opts) do
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

        TurnEvents.emit(on_message, :session_started, %{
          session_id: session_id,
          thread_id: thread_id,
          turn_id: turn_id
        })

        {:ok, tailer} = start_turn_tailer(session, turn_id, from, on_message)

        # Warm turns send AFTER the tailer attaches so no record is missed;
        # cold turns already sent the prompt to create the transcript.
        send_result = if prompt_sent?, do: :ok, else: PromptSubmit.send(session, prompt, opts)

        case send_result do
          :ok ->
            deadline = System.monotonic_time(:millisecond) + timeout_ms
            result = await_turn(session, tailer, turn_id, deadline, poll_ms, on_operator, pause_confirm_ms)
            stop_tailer(tailer)
            finish_turn(result, on_message, session_id, thread_id, turn_id)

          {:error, reason} ->
            stop_tailer(tailer)
            TurnEvents.emit(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason})
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_turn(:ok, on_message, session_id, thread_id, turn_id) do
    TurnEvents.emit(on_message, :turn_completed, %{session_id: session_id, turn_id: turn_id})
    {:ok, %{result: :completed, session_id: session_id, thread_id: thread_id, turn_id: turn_id}}
  end

  # A pause request interrupted this turn. The runner's `{:paused, _}` branch
  # reads `payload[:session_id]` for its log line — so the payload must carry the ids.
  defp finish_turn({:paused, payload}, on_message, session_id, thread_id, turn_id) do
    TurnEvents.emit(on_message, :turn_paused, %{session_id: session_id, turn_id: turn_id})

    {:paused,
     payload
     |> Map.put(:session_id, session_id)
     |> Map.put(:thread_id, thread_id)
     |> Map.put(:turn_id, turn_id)}
  end

  defp finish_turn({:error, reason}, on_message, session_id, _thread_id, _turn_id) do
    TurnEvents.emit(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason})
    {:error, reason}
  end

  # WARM — jsonl exists: tail from :end, send prompt after tailer attaches.
  # COLD — no jsonl yet: send prompt first to create the file, then tail from :start.
  defp prepare_turn(session, prompt, opts) do
    resolved = session.transcript_path || resolve_session_transcript(session)

    if is_binary(resolved) and File.exists?(resolved) do
      {:ok, resolved, :end, false}
    else
      with :ok <- PromptSubmit.send(session, prompt, opts),
           {:ok, path} <- await_transcript(session) do
        {:ok, path, :start, true}
      end
    end
  end

  # Ignore files older than spawn — `since: started_at` prevents tailing a prior run's jsonl.
  defp resolve_session_transcript(session) do
    RemoteControl.resolve_transcript_path(
      workspace: session.workspace,
      projects_dir: Map.get(session, :projects_dir),
      since: Map.get(session, :started_at, 0)
    )
  end

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

  # Capture `parent = self()` BEFORE start_link so `{:turn_end, …}` routes back
  # to the awaiting process, not the tailer's process.
  defp start_turn_tailer(session, turn_id, from, on_message) do
    parent = self()

    TranscriptTailer.start_link(
      path: session.transcript_path,
      from: from,
      turn_id: turn_id,
      interval_ms: nil,
      on_message: fn event -> TurnEvents.emit_transcript(on_message, event) end,
      on_turn_end: fn reason -> send(parent, {:turn_end, turn_id, reason}) end
    )
  end

  defp await_turn(session, tailer, turn_id, deadline, poll_ms, on_operator, pause_confirm_ms) do
    cond do
      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :turn_timeout}

      not Reaper.pane_alive?(session) ->
        {:error, :repl_gone}

      true ->
        TranscriptTailer.poll(tailer)

        receive do
          {:turn_end, ^turn_id, _reason} ->
            :ok

          {:agent_queue_updated, _identifier, _item_id, true} ->
            OperatorInject.deliver_immediate_operator_message(session, on_operator)
            await_turn(session, tailer, turn_id, deadline, poll_ms, on_operator, pause_confirm_ms)

          {:agent_queue_updated, _identifier, _item_id, _deliver_now} ->
            await_turn(session, tailer, turn_id, deadline, poll_ms, on_operator, pause_confirm_ms)

          {:agent_queue_updated, _identifier, _item_id} ->
            await_turn(session, tailer, turn_id, deadline, poll_ms, on_operator, pause_confirm_ms)

          # A failed interrupt still parks — the operator asked for a pause.
          {:pause_agent, request_id} when is_integer(request_id) ->
            case OperatorInject.interrupt(session) do
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

  # Expiry parks anyway — never `{:error, :turn_timeout}` (see @pause_confirm_ms).
  defp await_pause_confirm(tailer, turn_id, deadline, poll_ms) do
    if System.monotonic_time(:millisecond) >= deadline do
      Logger.warning("repl_pause pause_confirm_timeout turn_id=#{turn_id}")
      :timeout
    else
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

  defp stop_tailer(tailer) do
    if Process.alive?(tailer), do: GenServer.stop(tailer, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  # Thread id is the transcript file UUID; turn id appends a monotonic counter.
  defp turn_ids(transcript_path) do
    uuid = transcript_path |> Path.basename() |> Path.rootname()
    counter = System.unique_integer([:positive, :monotonic])
    {uuid, "#{uuid}-#{counter}"}
  end
end
