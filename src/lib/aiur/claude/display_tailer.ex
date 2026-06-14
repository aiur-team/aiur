defmodule Aiur.Claude.DisplayTailer do
  @moduledoc """
  Run-scoped, hook-driven DISPLAY feed for an RC-claude agent.

  An RC-claude agent's full conversation lives only in claude's transcript
  jsonl — thinking, intermediate assistant text, and tool input/output. The
  lifecycle hooks (`Aiur.Claude.HookEvents`) carry just tool names and the
  final message, so a pane driven from hooks alone is a sparse skeleton next
  to what the Remote Control channel shows. This GenServer mirrors the full
  transcript into the agent's opencode pane so the two surfaces are two views
  of one conversation.

  It learns the active session's `transcript_path` from the hook stream, runs
  an `Aiur.Claude.TranscriptTailer` over it (`from: :start`, so opening the
  pane mid-run backfills the whole conversation), forwards each extracted
  `Aiur.AgentEvents.transcript_event/3` to the run's `on_message`, and
  retargets when the session rotates to a new jsonl.

  DISPLAY-ONLY / READ-ONLY: it never sends keys or re-prompts the agent, and
  any tailer/parse/file failure degrades the view without touching turn
  detection or the agent run — it traps the inner tailer's exit and waits for
  the next hook to retarget. Turn detection stays on the hooks; this only
  paints the conversation.
  """

  use GenServer

  require Logger

  alias Aiur.Claude.{HookEvents, TranscriptTailer}

  # Cap oversized reasoning/tool bodies so a 10k-line tool dump or a long
  # thinking block can't flood the pane. Mirrors the spirit of the RC view's
  # own collapsing.
  @default_max_body 8_000

  # The inner tailer polls on this cadence in production; tests pass
  # `interval_ms: nil` and drive reads synchronously via `poll/1`.
  @default_interval_ms 400

  @type option ::
          {:identifier, String.t()}
          | {:on_message, (map() -> any())}
          | {:interval_ms, pos_integer() | nil}
          | {:max_body, pos_integer()}
          | {:name, GenServer.name()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Synchronously run one read cycle of the inner tailer. Tests only; production uses the timer."
  @spec poll(GenServer.server()) :: {:ok, non_neg_integer()}
  def poll(server), do: GenServer.call(server, :poll)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    identifier = Keyword.fetch!(opts, :identifier)
    on_message = Keyword.fetch!(opts, :on_message)
    :ok = HookEvents.subscribe(identifier)

    {:ok,
     %{
       identifier: identifier,
       on_message: on_message,
       interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
       max_body: Keyword.get(opts, :max_body, @default_max_body),
       path: nil,
       tailer: nil
     }}
  end

  @impl true
  def handle_info({:claude_hook, _id, %{transcript_path: path}}, state) when is_binary(path) do
    {:noreply, maybe_retarget(state, path)}
  end

  def handle_info({:claude_hook, _id, _event}, state), do: {:noreply, state}

  # The inner tailer died (parse loop crash, vanished file): drop it and wait
  # for the next hook to retarget. Display degrades; the agent run is untouched.
  def handle_info({:EXIT, pid, reason}, %{tailer: pid} = state) do
    Logger.warning("display_tailer inner_tailer_down identifier=#{state.identifier} reason=#{inspect(reason)}")
    {:noreply, %{state | tailer: nil, path: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:poll, _from, %{tailer: nil} = state), do: {:reply, {:ok, 0}, state}

  def handle_call(:poll, _from, %{tailer: tailer} = state) do
    {:reply, TranscriptTailer.poll(tailer), state}
  rescue
    _ -> {:reply, {:ok, 0}, state}
  end

  # Already tailing this path — nothing to do.
  defp maybe_retarget(%{path: path} = state, path), do: state

  defp maybe_retarget(state, path) do
    if File.exists?(path) do
      stop_tailer(state.tailer)

      case start_tailer(state, path) do
        {:ok, tailer} ->
          %{state | tailer: tailer, path: path}

        {:error, reason} ->
          Logger.warning("display_tailer start_failed identifier=#{state.identifier} reason=#{inspect(reason)}")
          %{state | tailer: nil, path: nil}
      end
    else
      # Path not flushed to disk yet (lazy flush). A later hook retargets.
      state
    end
  end

  defp start_tailer(state, path) do
    on_message = state.on_message
    max_body = state.max_body

    TranscriptTailer.start_link(
      path: path,
      from: :start,
      turn_id: nil,
      interval_ms: state.interval_ms,
      on_message: fn event -> forward(on_message, max_body, event) end,
      on_turn_end: fn _reason -> :ok end
    )
  end

  defp stop_tailer(nil), do: :ok

  defp stop_tailer(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  # Forward one transcript event to the run's on_message as a display event,
  # mirroring ReplAgent.emit_transcript/2's shape so it flows through the
  # runner's transcript broadcast path. Read-only: no agent input ever.
  defp forward(on_message, max_body, event) do
    on_message.(%{event: :transcript, transcript_event: cap(event, max_body), timestamp: DateTime.utc_now()})
  rescue
    _ -> :ok
  end

  defp cap(%{body: body} = event, max_body) when is_binary(body) do
    %{event | body: cap_text(body, max_body)}
    |> cap_payload(max_body)
  end

  defp cap(event, max_body), do: cap_payload(event, max_body)

  defp cap_payload(%{payload: %{} = payload} = event, max_body) do
    %{event | payload: cap_payload_field(payload, :output, max_body)}
  end

  defp cap_payload(event, _max_body), do: event

  defp cap_payload_field(payload, key, max_body) do
    case Map.get(payload, key) do
      value when is_binary(value) -> Map.put(payload, key, cap_text(value, max_body))
      _ -> payload
    end
  end

  defp cap_text(text, max_body) when byte_size(text) > max_body do
    dropped = byte_size(text) - max_body
    binary_part(text, 0, max_body) <> "\n…(#{dropped} bytes truncated)"
  end

  defp cap_text(text, _max_body), do: text
end
