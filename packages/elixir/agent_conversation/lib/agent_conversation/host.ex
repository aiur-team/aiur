defmodule AgentConversation.Host do
  @moduledoc """
  The embedding host contract: who is looking, what they may see, and how the
  component reaches their service.

  A host supplies four things and nothing else:

    * an authenticated `principal` value it alone understands,
    * a `AgentConversation.Scope` naming the tickets, games and conversations the
      principal may address,
    * a `transport` module implementing `AgentConversation.Host.Transport`,
    * `features` describing which surfaces the host wants mounted.

  The component never calls a service directly and never reads credentials. Every
  read, send, voice request and Command answer goes through the transport with
  the same principal and conversation, and is scope-checked first by
  `AgentConversation.Client`.
  """

  alias AgentConversation.Scope

  @enforce_keys [:principal, :scope, :transport]
  defstruct principal: nil, scope: nil, transport: nil, features: %{}, title: "Conversation"

  @type feature :: :send | :voice | :commands | :media | :minimap | :reveal
  @type t :: %__MODULE__{
          principal: term(),
          scope: Scope.t(),
          transport: module(),
          features: %{optional(feature()) => boolean() | :dictation | :two_way},
          title: String.t()
        }

  @default_features %{send: false, voice: false, commands: false, media: true, minimap: true, reveal: false}

  @doc """
  Builds a host record, defaulting every surface to the safe off state.

  `:features` is merged over the defaults so a host opts *into* sending, voice,
  Command answering and raw reveal instead of inheriting them.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_host}
  def new(opts) when is_list(opts) do
    with {:ok, principal} <- fetch(opts, :principal),
         {:ok, %Scope{} = scope} <- fetch(opts, :scope),
         {:ok, transport} when is_atom(transport) <- fetch(opts, :transport) do
      {:ok,
       %__MODULE__{
         principal: principal,
         scope: scope,
         transport: transport,
         features: Map.merge(@default_features, feature_map(Keyword.get(opts, :features, %{}))),
         title: Keyword.get(opts, :title, "Conversation") || "Conversation"
       }}
    else
      _ -> {:error, :invalid_host}
    end
  end

  def new(_opts), do: {:error, :invalid_host}

  @doc "Whether the host mounted `feature`. Voice reports its mode, not `true`."
  @spec feature(t(), feature()) :: boolean() | :dictation | :two_way
  def feature(%__MODULE__{features: features}, feature), do: Map.get(features, feature, false)

  @doc """
  Whether the host mounted `feature` at all.

  `:none` counts as not mounted, so a host that says "voice: :none" gets the
  unavailable state rather than a dead voice control.
  """
  @spec enabled?(t(), feature()) :: boolean()
  def enabled?(%__MODULE__{} = host, feature), do: feature(host, feature) in [true, :dictation, :two_way]

  @doc "Every surface name the host contract understands."
  @spec features() :: [feature()]
  def features, do: Map.keys(@default_features)

  defp fetch(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, nil} -> :error
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp feature_map(features) when is_map(features), do: Map.take(features, features())
  defp feature_map(_features), do: %{}
end

defmodule AgentConversation.Host.Transport do
  @moduledoc """
  The adapter an embedding host implements so the component can reach its
  service.

  Every callback receives the `AgentConversation.Host` (principal plus scope) and
  the conversation id the component already scope-checked. Implementations
  repeat the check against their own authorization source: the component's scope
  is a client-side guard, never the only one.

  Pages use the same shape as `AgentConversation.Timeline.merge/3` expects:
  `%{entries: [entry], head_pos: pos, prev_cursor: pos | nil, next_cursor: pos | nil,
  complete_from_start: boolean, sessions: [session]}`. Entries are maps with at
  least `:pos`, `:kind`, `:role` and `:body`; see `AgentConversation.Entry`.

  Denials use `:out_of_scope` and `:permission_denied` so the component can map
  them to its own states. Commands answer `{:error, {:conflict, summary}}` when
  another principal answered first.
  """

  alias AgentConversation.Host

  @type reason ::
          :out_of_scope | :permission_denied | :not_found | :unavailable | :invalid_request | atom()

  @doc "Reads one page of entries around the requested cursor."
  @callback read_entries(Host.t(), String.t(), keyword()) :: {:ok, map()} | {:error, reason()}

  @doc "Reads the jump anchors the minimap draws."
  @callback read_anchors(Host.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, reason()}

  @doc "Reads the Commands waiting for an answer in this conversation."
  @callback read_commands(Host.t(), String.t()) :: {:ok, [map()]} | {:error, reason()}

  @doc "Sends operator text into the conversation."
  @callback send_text(Host.t(), String.t(), String.t()) :: {:ok, map()} | {:error, reason()}

  @doc "Answers a pending Command through the host's own answering boundary."
  @callback answer_command(Host.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, reason()}

  @doc "Reports which voice modes this principal and conversation may use."
  @callback voice_capabilities(Host.t(), String.t()) :: {:ok, map()} | {:error, reason()}

  @optional_callbacks read_anchors: 3, read_commands: 2, answer_command: 4, voice_capabilities: 2
end
