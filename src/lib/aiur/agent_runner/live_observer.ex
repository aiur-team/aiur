defmodule Aiur.AgentRunner.LiveObserver do
  @moduledoc false

  require Logger
  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.{Issue, LiveConversation, TrackerIdentity}
  alias Aiur.Signal

  # This sits beside, rather than behind, the existing pane transcript. The
  # pane is intentionally rich (reasoning, commands, tool I/O); the dashboard
  # projection admits only its own conservative allowlist.
  @spec maybe_observe_live_conversation(Issue.t(), term(), keyword()) :: term()
  def maybe_observe_live_conversation(%Issue{} = issue, {:ok, event}, opts) do
    if display_tailer_authority?(opts) do
      :ok
    else
      backend = Keyword.get(opts, :backend)

      with_live_source(issue, backend, opts, :observe, fn source ->
        observe_live_event(issue, source, event, opts)
      end)
    end
  end

  def maybe_observe_live_conversation(_issue, _transcript_event, _opts), do: :ok

  defp observe_live_event(issue, source, %{role: :tool} = event, opts) do
    case safe_tool_summary(event) do
      {:ok, summary} ->
        safe_live_conversation(issue, :observe_tool, opts, fn ->
          LiveConversation.observe_tool_summary(source, summary, live_conversation_opts(opts, issue))
        end)

      :skip ->
        :ok
    end
  end

  # Codex does not expose a stable fragment identity for replayed deltas. Keep
  # rich partials in the pane transcript, but admit only the matching completed
  # message to the bounded public projection.
  defp observe_live_event(_issue, _source, %{kind: :assistant_delta}, _opts), do: :ok

  defp observe_live_event(issue, source, event, opts) do
    safe_live_conversation(issue, :observe, opts, fn ->
      LiveConversation.observe(source, event, live_conversation_opts(opts, issue))
    end)
  end

  # The rich transcript event contains tool inputs, output and paths. Reduce
  # only completed result shapes to fixed prose before crossing the projection
  # boundary; no provider-controlled tool content is retained.
  defp safe_tool_summary(%{payload: payload, msg_id: msg_id} = event)
       when is_map(payload) and (is_binary(msg_id) or is_integer(msg_id)) do
    case safe_tool_outcome(payload, event) do
      nil ->
        :skip

      outcome ->
        {:ok,
         %{
           msg_id: msg_id,
           title: "Tool result",
           body: outcome,
           timestamp: Map.get(event, :timestamp)
         }}
    end
  end

  defp safe_tool_summary(_event), do: :skip

  defp safe_tool_outcome(%{tool: "result"}, %{body: "tool result (error)"}),
    do: "Tool reported an error"

  defp safe_tool_outcome(%{tool: "result"}, _event), do: "Tool completed"
  defp safe_tool_outcome(%{success: true}, _event), do: "Tool completed"
  defp safe_tool_outcome(%{success: false}, _event), do: "Tool reported an error"
  defp safe_tool_outcome(_payload, _event), do: nil

  @doc false
  @spec observe_operator_delivery(Issue.t(), map(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def observe_operator_delivery(
        %Issue{} = issue,
        %{id: request_id, category: :operator_message} = item,
        backend,
        opts
      )
      when is_integer(request_id) and is_binary(backend) and is_list(opts) do
    text = QueueDrain.queue_item_text(item)

    case operator_delivery_opts(issue, item, opts) do
      {:ok, opts} -> observe_operator_text(issue, request_id, text, backend, opts)
      :buffered -> :ok
      {:error, _reason} = error -> error
    end
  end

  def observe_operator_delivery(_issue, _item, _backend, _opts), do: :ok

  defp observe_operator_text(_issue, _request_id, "", _backend, _opts), do: :ok

  defp observe_operator_text(issue, request_id, text, backend, opts) do
    with_live_source(issue, backend, opts, :observe_operator, fn source ->
      observe_operator_text_for_source(issue, source, request_id, text, opts)
    end)
  end

  defp observe_operator_text_for_source(issue, source, request_id, text, opts) do
    event =
      %{
        role: :user,
        msg_id: "operator:#{request_id}",
        body: text,
        payload: %{source: :operator_delivery}
      }
      |> maybe_put_occurred_at(Keyword.get(opts, :occurred_at))

    safe_live_conversation(issue, :observe_operator, opts, fn ->
      LiveConversation.observe_operator_message(source, event, live_conversation_opts(opts, issue))
    end)
  end

  @doc false
  @spec observe_display_transcript(Issue.t(), map(), String.t(), keyword()) :: :ok
  def observe_display_transcript(
        %Issue{} = issue,
        %{role: :user, payload: %{origin: :remote}} = event,
        backend,
        opts
      )
      when is_binary(backend) and is_list(opts) do
    with_live_source(issue, backend, opts, :observe_remote_operator, fn source ->
      safe_live_conversation(issue, :observe_remote_operator, opts, fn ->
        LiveConversation.observe_operator_message(source, event, live_conversation_opts(opts, issue))
      end)
    end)
  end

  def observe_display_transcript(%Issue{} = issue, %{role: role} = event, backend, opts)
      when role in [:assistant, :tool] and is_binary(backend) and is_list(opts) do
    with_live_source(issue, backend, opts, :observe_display, fn source ->
      observe_live_event(issue, source, event, opts)
    end)
  end

  def observe_display_transcript(_issue, _event, _backend, _opts), do: :ok

  @doc false
  @spec end_live_conversation(Issue.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def end_live_conversation(%Issue{} = issue, backend, opts) when is_binary(backend) and is_list(opts) do
    with_live_source(issue, backend, opts, :end_generation, fn source ->
      safe_live_conversation(issue, :end_generation, opts, fn ->
        LiveConversation.end_generation(source, live_conversation_opts(opts, issue))
      end)
    end)
  end

  def end_live_conversation(_issue, _backend, _opts), do: :ok

  @doc false
  @spec finish_live_conversation(Issue.t(), String.t(), term(), keyword()) ::
          :ok | {:error, term()}
  def finish_live_conversation(issue, backend, {:error, _reason}, opts),
    do: mark_live_conversation_degraded(issue, backend, opts)

  def finish_live_conversation(issue, backend, _result, opts),
    do: end_live_conversation(issue, backend, opts)

  @doc false
  @spec mark_live_conversation_degraded(Issue.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def mark_live_conversation_degraded(%Issue{} = issue, backend, opts)
      when is_binary(backend) and is_list(opts) do
    with_live_source(issue, backend, opts, :mark_degraded, fn source ->
      safe_live_conversation(issue, :mark_degraded, opts, fn ->
        LiveConversation.mark_degraded(source, live_conversation_opts(opts, issue))
      end)
    end)
  end

  def mark_live_conversation_degraded(_issue, _backend, _opts), do: :ok

  @doc false
  @spec activate_live_conversation(Issue.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def activate_live_conversation(%Issue{} = issue, backend, opts)
      when is_binary(backend) and is_list(opts) do
    case Keyword.get(opts, :live_conversation_authority) do
      :display_tailer -> :ok
      _authority -> activate_live_source(issue, backend, opts)
    end
  end

  def activate_live_conversation(_issue, _backend, _opts),
    do: {:error, {:live_conversation_context, :invalid_arguments}}

  defp activate_live_source(issue, backend, opts) do
    with_live_source(issue, backend, opts, :activate, fn source ->
      activate_live_source_projection(issue, source, opts)
    end)
  end

  defp activate_live_source_projection(issue, source, opts) do
    safe_live_conversation(issue, :activate, opts, fn ->
      LiveConversation.activate(source, live_conversation_opts(opts, issue))
    end)
  end

  @doc false
  @spec replace_live_conversation_source(
          Issue.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: :ok | {:error, term()}
  def replace_live_conversation_source(issue, backend, prior_session, next_session, opts)
      when is_binary(backend) and is_list(opts) do
    if prior_session != next_session do
      _ = end_live_conversation(issue, backend, Keyword.put(opts, :session_id, prior_session))
    end

    opts =
      opts
      |> Keyword.put(:session_id, next_session)
      |> Keyword.delete(:live_conversation_authority)

    activate_live_conversation(issue, backend, opts)
  end

  @doc false
  @spec live_source(Issue.t(), String.t(), keyword()) ::
          {:ok, map()} | {:skip, atom()} | {:error, atom()}
  def live_source(%Issue{} = issue, backend, opts)
      when is_binary(backend) and is_list(opts) do
    with :ok <- live_projection_enabled(opts),
         :ok <- valid_live_backend(backend),
         {:ok, identity} <- live_identity(issue),
         :ok <- joinable_live_identity(identity),
         {:ok, generation} <- live_worker_generation(opts),
         {:ok, attempt_id} <- live_source_attempt(opts) do
      {:ok,
       %{
         identity: identity,
         attempt_id: attempt_id,
         session_id: Keyword.get(opts, :session_id),
         backend: backend,
         worker_generation: generation
       }}
    end
  end

  def live_source(_issue, _backend, _opts), do: {:error, :invalid_arguments}

  defp live_projection_enabled(opts) do
    case Keyword.get(opts, :live_conversation) do
      :disabled -> {:skip, :disabled}
      _enabled -> :ok
    end
  end

  defp valid_live_backend(""), do: {:error, :invalid_backend}
  defp valid_live_backend(_backend), do: :ok

  defp live_identity(issue) do
    case Issue.tracker_identity(issue) do
      %TrackerIdentity{} = identity -> {:ok, identity}
      _missing -> {:error, :missing_identity}
    end
  end

  defp joinable_live_identity(identity) do
    case TrackerIdentity.joinable?(identity) do
      true -> :ok
      false -> {:error, :unjoinable_identity}
    end
  end

  defp live_worker_generation(opts) do
    case Keyword.get(opts, :worker_generation) do
      generation when is_integer(generation) and generation > 0 -> {:ok, generation}
      _missing -> {:error, :missing_worker_generation}
    end
  end

  defp live_source_attempt(opts) do
    case live_attempt_id(opts) do
      nil -> {:error, :missing_attempt_id}
      attempt_id -> {:ok, attempt_id}
    end
  end

  defp live_attempt_id(opts),
    do: Keyword.get(opts, :attempt_id) || Keyword.get(opts, :telemetry_attempt_id)

  defp live_conversation_opts(opts, %Issue{id: issue_id}) do
    []
    |> maybe_put_live_server(Keyword.get(opts, :live_conversation_server))
    |> Keyword.put(:history_known?, Keyword.get(opts, :live_conversation_history_known?, true))
    |> maybe_put_runtime_subscriber(projection_recipient(opts), issue_id)
  end

  defp with_live_source(issue, backend, opts, operation, fun) do
    case live_source(issue, backend, opts) do
      {:ok, source} ->
        fun.(source)

      {:skip, _reason} ->
        :ok

      {:error, reason} ->
        log_projection_failure(issue, operation, reason)
        {:error, {:live_conversation_context, reason}}
    end
  end

  defp safe_live_conversation(issue, operation, _opts, fun) do
    case fun.() do
      {:ok, snapshot} when is_map(snapshot) ->
        :ok

      {:error, reason} ->
        log_projection_failure(issue, operation, reason)
        {:error, {:live_conversation_projection, operation, reason}}
    end
  catch
    :exit, reason ->
      reason_class = Signal.reason_class(reason)
      log_projection_failure(issue, operation, reason_class)
      {:error, {:live_conversation_unavailable, operation}}
  end

  defp normalize_projection_reason(reason) when is_atom(reason), do: reason
  defp normalize_projection_reason(_reason), do: :projection_unavailable

  defp display_tailer_authority?(opts),
    do: Keyword.get(opts, :live_conversation_authority) == :display_tailer

  defp operator_delivery_opts(issue, item, opts) do
    if display_tailer_authority?(opts) do
      case resolve_source_session(Keyword.get(opts, :live_conversation_source_resolver)) do
        session_id when is_binary(session_id) and session_id != "" ->
          {:ok, Keyword.put(opts, :session_id, session_id)}

        _missing ->
          buffer_operator_delivery(issue, item, opts)
      end
    else
      {:ok, opts}
    end
  end

  defp resolve_source_session(resolver) when is_function(resolver, 0) do
    resolver.()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp resolve_source_session(_resolver), do: nil

  defp buffer_operator_delivery(issue, item, opts) do
    case Keyword.get(opts, :live_conversation_operator_buffer) do
      buffer when is_function(buffer, 2) ->
        case buffer.(item, Keyword.get(opts, :occurred_at)) do
          :ok -> :buffered
          _other -> missing_source_session(issue)
        end

      _missing ->
        missing_source_session(issue)
    end
  rescue
    _error -> missing_source_session(issue)
  catch
    _kind, _reason -> missing_source_session(issue)
  end

  defp missing_source_session(issue) do
    reason = :missing_source_session
    log_projection_failure(issue, :observe_operator, reason)
    {:error, {:live_conversation_context, reason}}
  end

  defp maybe_put_occurred_at(event, %DateTime{} = occurred_at),
    do: Map.put(event, :timestamp, occurred_at)

  defp maybe_put_occurred_at(event, _occurred_at), do: event

  defp maybe_put_live_server(opts, nil), do: opts
  defp maybe_put_live_server(opts, server), do: Keyword.put(opts, :server, server)

  defp maybe_put_runtime_subscriber(opts, recipient, issue_id)
       when is_pid(recipient) and is_binary(issue_id),
       do: Keyword.put(opts, :runtime_subscriber, {recipient, issue_id})

  defp maybe_put_runtime_subscriber(opts, _recipient, _issue_id), do: opts

  defp projection_recipient(opts) do
    Keyword.get(opts, :live_conversation_recipient) || Keyword.get(opts, :orchestrator)
  end

  defp log_projection_failure(issue, operation, reason) do
    Logger.warning(
      "Live conversation projection #{operation} failed for " <>
        "#{Aiur.AgentRunner.issue_context(issue)} " <>
        "reason_class=#{normalize_projection_reason(reason)}"
    )
  end
end
