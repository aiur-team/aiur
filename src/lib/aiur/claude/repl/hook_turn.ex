defmodule Aiur.Claude.Repl.HookTurn do
  @moduledoc """
  Hook-driven (RC) turn loop.

  Runs entirely in the caller's process as a plain function call — no Task, no
  GenServer. `{:pause_agent, id}` and `{:agent_queue_updated, …}` are sent to
  that calling process. `HookEvents.subscribe/1` / `unsubscribe/1` are wrapped
  in `try`/`after` to ensure cleanup.
  """

  require Logger

  alias Aiur.Claude.HookEvents
  alias Aiur.Claude.NotificationPolicy
  alias Aiur.Claude.Repl.OperatorInject
  alias Aiur.Claude.Repl.PromptSubmit
  alias Aiur.Claude.Repl.Reaper
  alias Aiur.Claude.Repl.TurnEvents

  # How often the turn loop polls pane liveness while a turn is in flight.
  # Deliberately duplicated from TranscriptTurn to keep the dependency graph
  # one-way — do not create a shared constants module.
  @turn_poll_ms 250

  # After a pause request interrupts the live turn (Ctrl+C to the pane), how
  # long to wait for the tailer to observe the turn closing before parking
  # the agent as paused anyway.
  @pause_confirm_ms 10_000

  @doc """
  Drive one hook-driven (RC) turn.

  Sends `prompt` via the hook/RC protocol, then waits on claude lifecycle hook
  events: PostToolUse streams progress and heartbeats the backstop, Stop
  completes the turn, and StopFailure reports terminal API failures. The loop
  runs in the caller's process.
  """
  @spec run(map(), String.t(), keyword()) :: {:ok, map()} | {:paused, map()} | {:error, term()}
  def run(session, prompt, opts) do
    # Hook-driven turn: claude v2.1.177 flushes its transcript lazily, so we drive
    # turn detection off lifecycle hooks (Aiur.Claude.HookEvents) instead. Send the
    # prompt, then wait on the agent's hook topic: PostToolUse streams progress and
    # heartbeats the backstop, Stop completes the turn with `last_assistant_message`,
    # and StopFailure ends it with an API error. There is no completion clock — only
    # a terminal hook, pane death, or a generous no-event backstop ends the wait —
    # so a turn that works silently for minutes is never failed.
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    on_operator = Keyword.get(opts, :on_operator_message, fn -> :noop end)
    poll_ms = Keyword.get(opts, :poll_interval_ms, @turn_poll_ms)
    timeout_ms = Keyword.get(opts, :turn_timeout_ms) || Aiur.Config.agent_turn_timeout_ms()
    pause_confirm_ms = Keyword.get(opts, :pause_confirm_ms, @pause_confirm_ms)
    identifier = session.identifier

    :ok = HookEvents.subscribe(identifier)

    try do
      case PromptSubmit.submit(session, prompt, opts) do
        :ok ->
          # Backstop deadline is reset by every hook event, so it only fires for a
          # session that has gone fully silent (no tools, no Stop) — not a long turn.
          deadline = System.monotonic_time(:millisecond) + timeout_ms

          loop = %{
            session: session,
            identifier: identifier,
            on_message: on_message,
            on_operator: on_operator,
            poll_ms: poll_ms,
            pause_confirm_ms: pause_confirm_ms,
            timeout_ms: timeout_ms
          }

          loop
          |> await_hook_turn(deadline, %{session_id: nil, message: nil})
          |> finish_hook_turn(on_message)

        {:error, reason} ->
          TurnEvents.emit(on_message, :turn_ended_with_error, %{reason: reason})
          {:error, reason}
      end
    after
      HookEvents.unsubscribe(identifier)
    end
  end

  # Receive loop driven by claude lifecycle hooks. Returns `:ok` (with the captured
  # response/session in `acc`), `{:paused, _}`, or `{:error, reason}`.
  defp await_hook_turn(loop, deadline, acc) do
    cond do
      not Reaper.pane_alive?(loop.session) ->
        {:error, :repl_gone}

      System.monotonic_time(:millisecond) >= deadline ->
        # No hook event at all within the (event-reset) backstop window: treat as a
        # stalled session. Not the normal completion path — that is the Stop event.
        Logger.warning("repl_hook_turn backstop_timeout identifier=#{loop.identifier}")
        {:error, :turn_timeout}

      true ->
        receive do
          {:claude_hook, _id, %{event: :stop} = event} ->
            {:ok, %{acc | session_id: event.session_id || acc.session_id, message: event.message}}

          {:claude_hook, _id, %{event: :stop_failure} = event} ->
            if NotificationPolicy.usage_limit_exhausted?(event.raw) do
              {:paused, NotificationPolicy.usage_limit_pause(event.raw)}
            else
              {:error, {:turn_failed, event.raw}}
            end

          {:claude_hook, _id, %{event: :post_tool_use} = event} ->
            # PostToolUse is a liveness heartbeat for turn detection only — the
            # conversation (incl. tool I/O) is painted by Aiur.Claude.DisplayTailer
            # from the transcript jsonl, so nothing is rendered from here.
            await_hook_turn(loop, reset_deadline(loop), merge_session(acc, event))

          {:claude_hook, _id, %{event: :user_prompt_submit} = event} ->
            await_hook_turn(loop, reset_deadline(loop), merge_session(acc, event))

          {:claude_hook, _id, _event} ->
            await_hook_turn(loop, reset_deadline(loop), acc)

          # An Executor message landed mid-turn. The REPL accepts input while the
          # agent works; type it straight in so claude's native queue folds it.
          {:agent_queue_updated, _identifier, _item_id, true} ->
            Logger.info("repl_hook_turn operator_immediate identifier=#{loop.identifier}")
            OperatorInject.deliver_immediate_operator_message(loop.session, loop.on_operator)
            await_hook_turn(loop, deadline, acc)

          {:agent_queue_updated, _identifier, _item_id, _deliver_now} ->
            await_hook_turn(loop, deadline, acc)

          {:agent_queue_updated, _identifier, _item_id} ->
            await_hook_turn(loop, deadline, acc)

          # Pause request: interrupt the live REPL turn (Ctrl+C to the pane).
          # A tmux delivery failure is not pause evidence; returning an error
          # lets the orchestrator expire the correlated request instead of
          # recording a pause while the REPL may still be working.
          {:pause_agent, request_id, generation} when is_integer(request_id) and is_integer(generation) ->
            interrupt_for_pause(loop.session, %{request_id: request_id, generation: generation, kind: :operator_pause})

          {:pause_agent, request_id} when is_integer(request_id) ->
            interrupt_for_pause(loop.session, %{request_id: request_id})
        after
          loop.poll_ms ->
            await_hook_turn(loop, deadline, acc)
        end
    end
  end

  defp reset_deadline(loop), do: System.monotonic_time(:millisecond) + loop.timeout_ms

  defp interrupt_for_pause(session, payload) do
    case OperatorInject.interrupt(session) do
      :ok ->
        {:paused, payload}

      {:error, reason} ->
        Logger.warning("repl_pause interrupt_failed reason=#{inspect(reason)}")
        {:error, {:pause_interrupt_failed, reason}}
    end
  end

  defp merge_session(acc, %{session_id: sid}) when is_binary(sid), do: %{acc | session_id: sid}
  defp merge_session(acc, _event), do: acc

  # Stop completed the turn. The assistant message is NOT rendered from here —
  # Aiur.Claude.DisplayTailer paints the full conversation from the transcript
  # jsonl (single display source). `message` is still returned so the runner
  # keeps its turn-completion bookkeeping (last_assistant_message).
  defp finish_hook_turn({:ok, %{message: message, session_id: session_id}}, on_message) do
    sid = session_id || "repl-#{System.unique_integer([:positive])}"
    TurnEvents.emit(on_message, :turn_completed, %{session_id: sid})
    # `thread_id` is the real claude session id (== transcript filename), which
    # the runner persists as the resume handle. Use the raw hook-reported id, not
    # the synthetic `repl-…` display fallback, so a turn whose hook never carried
    # a session id leaves no handle (it would point at no transcript) and the
    # next restart cold-starts. The transcript-driven path sets it the same way.
    {:ok, %{result: :completed, session_id: sid, thread_id: session_id, message: message}}
  end

  defp finish_hook_turn({:paused, payload}, on_message) do
    TurnEvents.emit(on_message, :turn_paused, %{session_id: payload[:session_id]})
    {:paused, payload}
  end

  defp finish_hook_turn({:error, reason}, on_message) do
    TurnEvents.emit(on_message, :turn_ended_with_error, %{reason: reason})
    {:error, reason}
  end
end
