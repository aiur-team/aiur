defmodule AgentConversation.Scope do
  @moduledoc """
  The ticket/game scope an embedding host grants to a conversation component.

  A host builds one scope per authenticated principal and hands it to
  `AgentConversation.Host`. A conversation becomes addressable only when it is
  registered with the ticket or game the host allows, so naming a conversation
  id from another ticket or game is denied before any transport call is made.

  Each registered conversation carries the actions it permits. Reads are the
  default; `:send`, `:voice` and `:answer_command` are granted explicitly so an
  embed can follow a conversation it may not write to.
  """

  defstruct tickets: [], games: [], conversations: %{}, actions: [:read]

  @type action :: :read | :send | :voice | :answer_command
  @type conversation :: %{ticket: String.t() | nil, game: String.t() | nil, actions: [action()]}
  @type t :: %__MODULE__{
          tickets: [String.t()],
          games: [String.t()],
          conversations: %{optional(String.t()) => conversation()},
          actions: [action()]
        }

  @actions [:read, :send, :voice, :answer_command]
  @denials [:out_of_scope, :permission_denied, :unknown_action]

  @doc """
  Builds a scope from `tickets`, `games` and an optional default action list.

  Unknown options are rejected so a host cannot believe it granted something
  the component silently ignores.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_scope}
  def new(opts) when is_list(opts) do
    case Keyword.keys(opts) -- [:tickets, :games, :actions] do
      [] -> build(opts)
      _unknown -> {:error, :invalid_scope}
    end
  end

  def new(_opts), do: {:error, :invalid_scope}

  defp build(opts) do
    actions = actions(Keyword.get(opts, :actions, [:read]))

    case actions do
      {:ok, actions} ->
        {:ok,
         %__MODULE__{
           tickets: strings(Keyword.get(opts, :tickets, [])),
           games: strings(Keyword.get(opts, :games, [])),
           actions: actions
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Registers a conversation with its owner ticket/game and the actions it permits.

  Registering a conversation whose ticket and game both fall outside the scope
  is refused, which is what makes cross-scope access structural rather than a
  convention the transport has to remember.
  """
  @spec grant(t(), String.t(), keyword() | [action()]) ::
          {:ok, t()} | {:error, :out_of_scope | :invalid_scope}
  def grant(%__MODULE__{} = scope, conversation_id, opts) when is_binary(conversation_id) do
    {owner, actions} =
      if Keyword.keyword?(opts) and opts != [] do
        {Keyword.take(opts, [:ticket, :game]), Keyword.get(opts, :actions, scope.actions)}
      else
        {%{}, opts}
      end

    with true <- in_scope?(scope, owner, conversation_id),
         {:ok, actions} <- actions(actions) do
      {:ok,
       %{
         scope
         | conversations:
             Map.put(scope.conversations, conversation_id, %{
               ticket: owner[:ticket],
               game: owner[:game],
               actions: actions
             })
       }}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :out_of_scope}
    end
  end

  @doc "The conversation's registered owner, or a typed denial."
  @spec conversation(t(), String.t()) :: {:ok, conversation()} | {:error, :out_of_scope}
  def conversation(%__MODULE__{conversations: conversations}, conversation_id) do
    case Map.fetch(conversations, conversation_id) do
      {:ok, conversation} -> {:ok, conversation}
      :error -> {:error, :out_of_scope}
    end
  end

  @doc "Whether the scope permits `action` on `conversation_id`."
  @spec allows?(t(), String.t(), action()) :: boolean()
  def allows?(%__MODULE__{} = scope, conversation_id, action), do: check(scope, conversation_id, action) == :ok

  @doc """
  Checks one action for one conversation.

  Returns `:ok`, `{:error, :out_of_scope}` for a conversation the host did not
  register, `{:error, :permission_denied}` when the registration omits the
  action, or `{:error, :unknown_action}` for a name outside the action set.
  """
  @spec check(t(), String.t(), action()) :: :ok | {:error, atom()}
  def check(%__MODULE__{} = scope, conversation_id, action) do
    with {:ok, action} <- validate_action(action),
         {:ok, conversation} <- conversation(scope, conversation_id) do
      if action in conversation.actions or (action == :read and :read in conversation.actions) do
        :ok
      else
        {:error, :permission_denied}
      end
    end
  end

  @doc "The registered conversation ids, in the stable order the host supplied."
  @spec conversations(t()) :: [String.t()]
  def conversations(%__MODULE__{conversations: conversations}), do: conversations |> Map.keys() |> Enum.sort()

  @doc "Every action name the scope understands."
  @spec actions() :: [action()]
  def actions, do: @actions

  @doc "Every denial reason `check/3` can return."
  @spec denials() :: [atom()]
  def denials, do: @denials

  defp in_scope?(scope, owner, conversation_id) do
    ticket_allowed = owner[:ticket] != nil and owner[:ticket] in scope.tickets
    game_allowed = owner[:game] != nil and owner[:game] in scope.games
    registered = Map.has_key?(scope.conversations, conversation_id)
    ticket_allowed or game_allowed or registered
  end

  defp validate_action(action) when action in @actions, do: {:ok, action}
  defp validate_action(_action), do: {:error, :unknown_action}

  defp actions(actions) when is_list(actions) do
    Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, acc} ->
      case validate_action(action) do
        {:ok, action} -> {:cont, {:ok, Enum.uniq([action | acc])}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, actions} -> {:ok, Enum.reverse(actions)}
      error -> error
    end
  end

  defp actions(_actions), do: {:error, :invalid_scope}

  defp strings(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp strings(value) when is_binary(value), do: [value]
  defp strings(_values), do: []
end
