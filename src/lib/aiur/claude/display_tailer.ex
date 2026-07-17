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
  alias Aiur.LiveConversation.Source
  alias Aiur.RunTelemetry.Lifecycle

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
          | {:on_source, (source_event() -> any())}
          | {:initial_session_id, String.t() | nil}
          | {:log_context, String.t()}
          | {:interval_ms, pos_integer() | nil}
          | {:max_body, pos_integer()}
          | {:owner, pid()}
          | {:name, GenServer.name()}

  @type source_event ::
          {:available, String.t() | nil, String.t()}
          | {:unavailable, String.t() | nil, String.t(), atom()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Start UNLINKED, so a display failure can never take down the caller (the
  agent run). Pass `owner: self()` to have the tailer self-terminate if the
  run process dies — no leak even on a brutal kill that skips normal teardown.
  """
  @spec start([option()]) :: GenServer.on_start()
  def start(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start(__MODULE__, opts, gen_opts)
  end

  @doc "Synchronously run one read cycle of the inner tailer. Tests only; production uses the timer."
  @spec poll(GenServer.server()) :: {:ok, non_neg_integer()}
  def poll(server), do: GenServer.call(server, :poll)

  @doc false
  @spec current_session(GenServer.server()) :: String.t() | nil
  def current_session(server), do: GenServer.call(server, :current_session)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    identifier = Keyword.fetch!(opts, :identifier)
    on_message = Keyword.fetch!(opts, :on_message)
    on_source = Keyword.get(opts, :on_source, fn _event -> :ok end)
    :ok = HookEvents.subscribe(identifier)

    owner_ref =
      case Keyword.get(opts, :owner) do
        owner when is_pid(owner) -> Process.monitor(owner)
        _ -> nil
      end

    {:ok,
     %{
       identifier: identifier,
       on_message: on_message,
       on_source: on_source,
       log_context: Keyword.get(opts, :log_context, "issue_identifier=#{identifier}"),
       interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
       max_body: Keyword.get(opts, :max_body, @default_max_body),
       owner_ref: owner_ref,
       session_id: normalize_session_id(Keyword.get(opts, :initial_session_id)),
       path: nil,
       tailer: nil
     }}
  end

  @impl true
  def handle_info({:claude_hook, _id, %{transcript_path: path} = event}, state)
      when is_binary(path) and path != "" do
    session_id = session_id(event, path)
    {:noreply, maybe_retarget(state, path, session_id)}
  end

  def handle_info({:claude_hook, _id, _event}, state), do: {:noreply, state}

  # The inner tailer died (parse loop crash, vanished file): drop it and wait
  # for the next hook to retarget. Display degrades; the agent run is untouched.
  def handle_info({:EXIT, pid, reason}, %{tailer: pid} = state) do
    log_failure(state, :inner_tailer_down, reason)
    notify_source(state, {:unavailable, state.session_id, required_session_id(state), :inner_tailer_down})
    {:noreply, %{state | tailer: nil, path: nil}}
  end

  # The owning agent run died: stop following its transcript and shut down.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    stop_tailer(state.tailer)
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:current_session, _from, state), do: {:reply, state.session_id, state}

  def handle_call(:poll, _from, %{tailer: nil} = state), do: {:reply, {:ok, 0}, state}

  def handle_call(:poll, _from, %{tailer: tailer} = state) do
    {:reply, TranscriptTailer.poll(tailer), state}
  rescue
    _ -> {:reply, {:ok, 0}, state}
  end

  # Already tailing this exact source — nothing to do.
  defp maybe_retarget(
         %{path: path, session_id: session_id, tailer: tailer} = state,
         path,
         session_id
       )
       when is_pid(tailer),
       do: state

  defp maybe_retarget(state, path, session_id) do
    prior_session = state.session_id

    if File.exists?(path) do
      stop_tailer(state.tailer)

      case start_tailer(state, path, session_id) do
        {:ok, tailer} ->
          notify_source(state, {:available, prior_session, session_id})
          %{state | tailer: tailer, path: path, session_id: session_id}

        {:error, reason} ->
          log_failure(state, :start_failed, reason, session_id)
          notify_source(state, {:unavailable, prior_session, session_id, :tailer_start_failed})
          %{state | tailer: nil, path: nil, session_id: session_id}
      end
    else
      # Path not flushed to disk yet (lazy flush). Stop an older source now so
      # it cannot remain falsely healthy while we wait for a later hook.
      stop_tailer(state.tailer)
      log_failure(state, :transcript_unavailable, :enoent, session_id)
      notify_source(state, {:unavailable, prior_session, session_id, :transcript_unavailable})
      %{state | tailer: nil, path: nil, session_id: session_id}
    end
  end

  defp start_tailer(state, path, session_id) do
    on_message = state.on_message
    max_body = state.max_body

    TranscriptTailer.start_link(
      path: path,
      from: :start,
      turn_id: nil,
      interval_ms: state.interval_ms,
      on_message: fn event -> forward(on_message, max_body, session_id, event) end,
      on_turn_end: fn _reason -> :ok end
    )
  end

  defp session_id(%{session_id: session_id}, _path)
       when is_binary(session_id) and session_id != "",
       do: session_id

  defp session_id(_event, path), do: path |> Path.basename() |> Path.rootname()

  defp normalize_session_id(session_id) when is_binary(session_id) and session_id != "",
    do: session_id

  defp normalize_session_id(_session_id), do: nil

  defp required_session_id(%{session_id: session_id}) when is_binary(session_id), do: session_id
  defp required_session_id(state), do: "unresolved:#{state.identifier}"

  defp notify_source(state, event) do
    case state.on_source.(event) do
      {:error, reason} -> log_failure(state, :source_callback_failed, reason)
      _result -> :ok
    end
  rescue
    error ->
      log_failure(state, :source_callback_failed, error)
      :ok
  catch
    kind, reason ->
      log_failure(state, :source_callback_failed, {kind, reason})
      :ok
  end

  defp log_failure(state, operation, reason, session_id \\ nil) do
    session_id = session_id || state.session_id
    opaque_session = Source.opaque_session_id(session_id) || "session:unresolved"

    Logger.warning(
      "display_tailer #{operation} #{state.log_context} " <>
        "session=#{opaque_session} reason_class=#{Lifecycle.reason_class(reason)}"
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
  defp forward(on_message, max_body, session_id, event) do
    on_message.(%{
      event: :transcript,
      source_session_id: session_id,
      transcript_event: cap(event, max_body),
      timestamp: DateTime.utc_now()
    })
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
