defmodule Aiur.OpenAICompat.Handoff do
  @moduledoc """
  Daemon handoff for OpenAI-compatible sessions.

  These backends speak in-process HTTP: their conversation lives in this
  daemon's `Aiur.OpenAICompat.Session` agent, not in a child process that a
  successor daemon could re-attach to. A `restart --keep-agents` therefore
  serializes the conversation at a safe step boundary, and the successor daemon
  resolves fresh credentials and seeds a new session from it, so each ticket
  continues without a cold re-dispatch.

  The resolved provider config carries the API key, so the config itself is
  deliberately never written to the handoff record: the conversation, thread id,
  turn counters and the model the session resolved travel instead. The successor
  re-resolves `Aiur.OpenAICompat.Config` from the same session options it already
  had, with the recorded model as the default.
  """

  alias Aiur.AgentRunner.Handoff, as: RunnerHandoff
  alias Aiur.OpenAICompat.{CodingAgent, Session}

  @transport_kind "in_daemon"

  @doc "The transport kind an in-daemon session's handoff record carries."
  @spec transport_kind() :: String.t()
  def transport_kind, do: @transport_kind

  @doc """
  Serialize the live conversation for a handoff record.

  `state` is the run loop's in-flight state when a handoff arrives mid-turn (the
  `Session` agent is only updated when a turn commits); when it is `nil` the
  committed `Session` state is read instead. Returns only JSON-safe, secret-free
  fields.
  """
  @spec snapshot(map(), map() | nil) :: {:ok, map()} | {:error, term()}
  def snapshot(session, state \\ nil) do
    with {:ok, source} <- source_state(session, state) do
      {:ok,
       %{
         "thread_id" => Map.get(source, :thread_id),
         "turn_index" => Map.get(source, :turn_index, 0),
         "next_request_id" => Map.get(source, :next_request_id, 1),
         "messages" => Map.get(source, :messages, []),
         "model" => resolved_model(source),
         "interrupted" => not is_nil(state)
       }}
    end
  end

  # The model this session resolved from its dispatch-time options: for an
  # OpenAI-compatible backend that is the model segment of the winning
  # `agent.priority` route, which `backend_configs.<backend>` need not carry. It
  # travels so the successor starts the same model rather than falling back with
  # `:missing_model` (#7548). The API key stays behind — only the model string
  # crosses the restart.
  defp resolved_model(%{config: %{model: model}}) when is_binary(model) and model != "", do: model
  defp resolved_model(_source), do: nil

  defp source_state(_session, %{} = state), do: {:ok, state}

  defp source_state(%{session_pid: pid}, nil) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, Session.get(pid)}, else: {:error, :session_closed}
  end

  defp source_state(_session, nil), do: {:error, :session_closed}

  @doc """
  Start a fresh session and seed it with the record's saved conversation.

  The successor daemon owns the credentials and config resolution, so the
  restored session is a normal `start_session/2` result whose agent state is
  replaced with the saved messages, thread id and turn counters.
  """
  @spec restore(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def restore(record, opts) do
    with {:ok, provider_state} <- provider_state(record),
         opts = start_opts(opts, record, provider_state),
         workspace when is_binary(workspace) <- record["workspace"] || Keyword.get(opts, :workspace),
         {:ok, session} <- CodingAgent.start_session(workspace, Keyword.put(opts, :workspace, workspace)) do
      :ok = seed(session, provider_state)

      {:ok,
       session
       |> Map.put(:resumed, false)
       |> Map.put(:thread_id, Map.get(provider_state, "thread_id") || Map.get(session, :thread_id))
       |> tag_backend(record, opts)}
    else
      nil -> {:error, :workspace_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  # Credential and transport seams cannot cross a restart: a serialized record
  # carries metadata placeholders instead of the closures the old daemon passed.
  # Dropping them lets `Aiur.OpenAICompat.Config` resolve the successor daemon's
  # own credentials, which is what a keep-agents restart should use.
  @unserialized_seams [:api_key_fetcher, :request_fun, :backend_config_fetcher, :on_message, :run_turn]

  defp start_opts(opts, record, provider_state) do
    opts
    |> Keyword.put_new(:backend, record["backend"])
    |> put_saved_model(record, provider_state)
    |> Enum.reject(fn {key, value} -> key in @unserialized_seams and not is_function(value) end)
  end

  # The dispatch-time session options that carried the route's model never enter
  # the record's turn context, so a successor resolving the config from the
  # backend alone failed with `:missing_model` whenever the model lived only in
  # the route (#7548). The snapshot records the model the session ran with;
  # records written before that field existed still carry it in the saved session
  # map. An explicit option always wins over the saved value.
  defp put_saved_model(opts, record, provider_state) do
    saved = Map.get(provider_state, "model") || saved_session_model(record)

    if usable_model?(Keyword.get(opts, :model)) or not usable_model?(saved),
      do: opts,
      else: Keyword.put(opts, :model, saved)
  end

  defp saved_session_model(record) do
    case record["session_state"] && RunnerHandoff.decode(record["session_state"]) do
      %{model: model} when is_binary(model) and model != "" -> model
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp usable_model?(model), do: is_binary(model) and String.trim(model) != ""

  # The runner tags a freshly started session with its resolved backend; an
  # adopted session must carry the same tag or later dispatch cannot resolve its
  # adapter.
  defp tag_backend(session, record, opts) do
    backend = record["backend"] || Keyword.get(opts, :backend)

    session
    |> Map.put(:backend, backend)
    |> Map.put(:model, Map.get(session, :model) || Keyword.get(opts, :model))
  end

  # `CodingAgent.start_session/2` always returns a live session pid, so the
  # restored conversation is seeded into that agent directly.
  defp seed(%{session_pid: pid}, provider_state) when is_pid(pid) do
    Session.update(pid, fn state ->
      %{
        state
        | messages: Map.get(provider_state, "messages", []),
          thread_id: Map.get(provider_state, "thread_id") || Map.get(state, :thread_id),
          turn_index: Map.get(provider_state, "turn_index", Map.get(state, :turn_index, 0)),
          next_request_id: Map.get(provider_state, "next_request_id", Map.get(state, :next_request_id, 1))
      }
    end)
  end

  @doc "Decode a record's saved conversation, failing loud on a damaged snapshot."
  @spec provider_state(map()) :: {:ok, map()} | {:error, term()}
  def provider_state(%{"transport" => %{"provider_state" => encoded}}) when is_binary(encoded) do
    case RunnerHandoff.decode(encoded) do
      %{} = state -> {:ok, state}
      _ -> {:error, :provider_state_invalid}
    end
  rescue
    _ -> {:error, :provider_state_invalid}
  end

  def provider_state(_record), do: {:error, :provider_state_missing}

  @doc "Encode a conversation for a handoff record's transport metadata."
  @spec encode_provider_state(map()) :: String.t()
  def encode_provider_state(state) when is_map(state),
    do: RunnerHandoff.encode(state)

  @doc "Whether the snapshot was taken mid-turn, so adoption continues that turn."
  @spec interrupted?(map()) :: boolean()
  def interrupted?(record) do
    case provider_state(record) do
      {:ok, state} -> Map.get(state, "interrupted") == true
      _ -> false
    end
  end
end
