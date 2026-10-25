defmodule AiurWeb.OperatorControlCenter.OperatorSend do
  @moduledoc """
  The dashboard's one path for an Executor message to a running agent.

  The Units drawer and the build home composer both send through here, so the
  #2717 retry rule and the `:agent_chat_send_fun` test seam live in one place.
  """

  alias Aiur.AgentChat
  alias Aiur.LiveConversation.Source
  alias Aiur.TrackerIdentity
  alias AiurWeb.EndpointConfig

  @type composer :: %{
          optional(:tracker_identity) => TrackerIdentity.t() | nil,
          optional(:target_key) => String.t(),
          required(:issue_identifier) => term(),
          optional(:writable_target?) => boolean()
        }
  @type pending :: %{optional(String.t()) => {String.t(), String.t()}}

  @spec target(composer()) :: TrackerIdentity.t() | String.t()
  def target(%{tracker_identity: %TrackerIdentity{} = identity}), do: identity
  def target(%{issue_identifier: identifier}), do: to_string(identifier)

  @spec key(composer()) :: String.t()
  def key(%{target_key: key}) when is_binary(key), do: key
  def key(%{issue_identifier: identifier}), do: to_string(identifier)

  @doc "The kept id when the pending text for `key` is unchanged, else a new one."
  @spec message_id(pending(), String.t(), String.t()) :: String.t()
  def message_id(pending, key, text) do
    case Map.get(pending, key) do
      {message_id, ^text} -> message_id
      _new_action -> "dashboard-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    end
  end

  # Each Send press is one user action with its own message id (#2717). When
  # the daemon does not answer in time, the outcome is unknown: the id is kept
  # in `pending`, so pressing Send again with the same text retries this send
  # and cannot queue a copy. Any other result drops it. A changed draft is a
  # new message and gets a new id.
  @spec send(composer(), String.t(), pending()) ::
          {:ok, integer(), String.t(), pending()} | {:error, term(), String.t() | nil, pending()}
  def send(_composer, "", pending), do: {:error, :empty_message, nil, pending}

  def send(composer, text, pending) when is_binary(text) do
    key = key(composer)
    message_id = message_id(pending, key, text)

    case send_agent_message(target(composer), text, message_id) do
      {:ok, request_id} -> {:ok, request_id, message_id, Map.delete(pending, key)}
      {:error, {:outcome_unknown, _info} = reason} -> {:error, reason, message_id, Map.put(pending, key, {message_id, text})}
      {:error, reason} -> {:error, reason, message_id, Map.delete(pending, key)}
    end
  end

  @spec delivery_status(integer(), timeout()) :: {:ok, atom()} | {:error, term()}
  def delivery_status(request_id, timeout) when is_integer(request_id) do
    case EndpointConfig.get(:agent_chat_delivery_status_fun) do
      fun when is_function(fun, 2) -> fun.(request_id, timeout)
      _fun -> AgentChat.delivery_status(request_id, timeout)
    end
  end

  @doc "The live-conversation id the agent's claim of `request_id` is recorded under."
  @spec transcript_id(integer()) :: String.t()
  def transcript_id(request_id) when is_integer(request_id), do: Source.opaque_id("message:", "operator:#{request_id}")

  defp send_agent_message(target, text, message_id) do
    case EndpointConfig.get(:agent_chat_send_fun) do
      fun when is_function(fun, 3) -> fun.(target, text, message_id: message_id)
      fun when is_function(fun, 2) -> fun.(target, text)
      _fun -> AgentChat.send(target, text, message_id: message_id)
    end
  end
end
