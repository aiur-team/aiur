defmodule Aiur.AgentRunner.SessionDisplay do
  @moduledoc false
  require Logger
  alias Aiur.AgentPubSub
  alias Aiur.AgentRunner.MessageHandler
  alias Aiur.Claude.DisplayTailer
  alias Aiur.CodingAgent
  alias Aiur.Issue
  alias Aiur.LiveConversation.Source
  alias Aiur.Signal
  import Aiur.AgentRunner.SessionIdentity

  @doc false
  @spec put_live_conversation_session_id(term(), term()) :: term()
  def put_live_conversation_session_id(opts, %{thread_id: thread_id})
      when is_binary(thread_id) and thread_id != "" do
    Keyword.put(opts, :session_id, thread_id)
  end

  def put_live_conversation_session_id(opts, _session), do: opts

  @doc false
  @spec maybe_put_display_authority(term(), term()) :: term()
  def maybe_put_display_authority(opts, true),
    do: Keyword.put(opts, :live_conversation_authority, :display_tailer)

  def maybe_put_display_authority(opts, false), do: opts

  @doc false
  @spec current_display_source_opts(term(), term()) :: term()
  def current_display_source_opts(opts, nil), do: opts

  def current_display_source_opts(opts, display_tailer) do
    case DisplayTailer.current_session(display_tailer) do
      session_id when is_binary(session_id) and session_id != "" ->
        Keyword.put(opts, :session_id, session_id)

      _other ->
        opts
    end
  catch
    :exit, _reason -> opts
  end

  @doc false
  @spec maybe_put_display_source_resolver(term(), term()) :: term()
  def maybe_put_display_source_resolver(opts, nil), do: opts

  def maybe_put_display_source_resolver(opts, display_tailer) do
    opts
    |> Keyword.put(:live_conversation_source_resolver, fn ->
      DisplayTailer.current_session(display_tailer)
    end)
    |> Keyword.put(:live_conversation_operator_buffer, fn item, occurred_at ->
      DisplayTailer.buffer_operator_delivery(display_tailer, item, occurred_at)
    end)
  end

  @doc false
  @spec maybe_start_display_tailer(term(), term(), term(), term()) :: term()
  def maybe_start_display_tailer(session, issue, rc?, opts) do
    backend = session_backend!(session)

    if should_display_tail?(backend, rc?, issue.identifier) do
      # DISPLAY-ONLY: broadcast straight to the opencode pane's transcript
      # topic. Do NOT route through codex_message_handler — that also does
      # per-record AgentEventLog.write (disk) and send_codex_update (to the
      # shared run recipient), so a `from: :start` backfill burst would hammer
      # both. The pane render only needs the transcript broadcast.
      on_message = display_tailer_handler(issue, backend, opts)
      on_source = display_tailer_source_handler(issue, backend, opts)
      on_operator_delivery = display_tailer_operator_delivery_handler(issue, backend, opts)

      # Until a hook identifies a readable transcript, the sole authoritative
      # RC conversation source is unavailable. Ordinary provider activation is
      # suppressed by `:live_conversation_authority` and cannot clear this.
      _ = MessageHandler.mark_live_conversation_degraded(issue, backend, opts)

      case DisplayTailer.start(
             identifier: issue.identifier,
             on_message: on_message,
             on_source: on_source,
             on_operator_delivery: on_operator_delivery,
             initial_session_id: Keyword.get(opts, :session_id),
             log_context: "#{Aiur.AgentRunner.issue_context(issue)} backend=#{backend}",
             owner: self()
           ) do
        {:ok, pid} ->
          pid

        {:error, reason} ->
          Logger.warning(
            "display_tailer start_failed #{Aiur.AgentRunner.issue_context(issue)} " <>
              "backend=#{backend} session=#{opaque_live_session(opts)} " <>
              "reason_class=#{Signal.reason_class(reason)}"
          )

          nil
      end
    else
      nil
    end
  end

  @doc false
  @spec display_tailer_handler(Issue.t(), String.t(), keyword()) :: (map() -> :ok)
  def display_tailer_handler(%Issue{identifier: identifier} = issue, backend, opts)
      when is_binary(identifier) and is_binary(backend) and is_list(opts) do
    fn
      %{
        source_session_id: session_id,
        projection_ingress: :display_backfill,
        transcript_event: event
      }
      when is_binary(session_id) and is_map(event) ->
        AgentPubSub.broadcast_transcript(identifier, event)

      %{source_session_id: session_id, transcript_event: event}
      when is_binary(session_id) and is_map(event) ->
        AgentPubSub.broadcast_transcript(identifier, event)

        MessageHandler.observe_display_transcript(
          issue,
          event,
          backend,
          Keyword.put(opts, :session_id, session_id)
        )

      _ ->
        :ok
    end
  end

  @doc false
  @spec display_tailer_source_handler(Issue.t(), String.t(), keyword()) ::
          (DisplayTailer.source_event() -> :ok | {:error, term()})
  def display_tailer_source_handler(%Issue{} = issue, backend, opts)
      when is_binary(backend) and is_list(opts) do
    fn
      {:available, prior_session, next_session, %{backfill?: backfill?}}
      when is_boolean(backfill?) ->
        opts = Keyword.put(opts, :live_conversation_history_known?, not backfill?)

        MessageHandler.replace_live_conversation_source(
          issue,
          backend,
          prior_session,
          next_session,
          opts
        )

      {:available, prior_session, next_session} ->
        MessageHandler.replace_live_conversation_source(
          issue,
          backend,
          prior_session,
          next_session,
          opts
        )

      {:unavailable, prior_session, next_session, _reason} ->
        opts = Keyword.put(opts, :live_conversation_history_known?, false)

        _ =
          MessageHandler.replace_live_conversation_source(
            issue,
            backend,
            prior_session,
            next_session,
            opts
          )

        MessageHandler.mark_live_conversation_degraded(
          issue,
          backend,
          Keyword.put(opts, :session_id, next_session)
        )

      _other ->
        :ok
    end
  end

  defp display_tailer_operator_delivery_handler(issue, backend, opts) do
    fn item, occurred_at, session_id ->
      opts =
        opts
        |> Keyword.put(:session_id, session_id)
        |> Keyword.put(:occurred_at, occurred_at)
        |> Keyword.delete(:live_conversation_authority)

      MessageHandler.observe_operator_delivery(issue, item, backend, opts)
    end
  end

  defp opaque_live_session(opts) do
    Source.opaque_session_id(Keyword.get(opts, :session_id)) ||
      "session:unresolved"
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

  @doc false
  @spec start_adopted_display(map(), Issue.t(), keyword()) :: {pid() | nil, keyword()}
  def start_adopted_display(session, issue, opts) do
    rc? = Map.get(session, :remote_control, false)
    opts = opts |> put_live_conversation_session_id(session) |> maybe_put_display_authority(should_display_tail?(session_backend!(session), rc?, issue.identifier))
    tailer = maybe_start_display_tailer(session, issue, rc?, opts)
    if tailer, do: DisplayTailer.restore_handoff(tailer, Keyword.get(opts, :handoff_display_state))
    Process.put(:handoff_display_tailer, tailer)
    {tailer, maybe_put_display_source_resolver(opts, tailer)}
  end

  @doc false
  @spec stop_display_tailer(pid() | nil) :: :ok
  def stop_display_tailer(nil), do: :ok

  def stop_display_tailer(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end
end
