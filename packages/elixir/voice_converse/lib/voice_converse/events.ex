defmodule VoiceConverse.Events do
  @moduledoc """
  Normalized conversation events (voice-session contract §4.1). A provider adapter turns every
  provider frame into one of these structs and sends it to the session owner as
  `{:voice_conversation, ref, event}`. No provider event name or field passes the adapter.

  A provider that cannot emit an event leaves it out of `capabilities/0` `:events`.
  """

  defmodule UserTranscript do
    @moduledoc "What the user said. `final?` is synthesized by the adapter when the provider has no flag."
    @enforce_keys [:text, :final?]
    defstruct [:text, :final?]
    @type t :: %__MODULE__{text: String.t(), final?: boolean()}
  end

  defmodule AgentText do
    @moduledoc "Assistant text for one turn."
    @enforce_keys [:turn_id, :text, :final?]
    defstruct [:turn_id, :text, :final?]
    @type t :: %__MODULE__{turn_id: term(), text: String.t(), final?: boolean()}
  end

  defmodule AgentAudio do
    @moduledoc "One base64 PCM chunk for a turn. Each chunk carries its own format; the client reads the rate from it."
    @enforce_keys [:turn_id, :format, :data_b64]
    defstruct [:turn_id, :format, :data_b64]

    @type format :: :pcm_16000 | :pcm_24000 | :pcm_44100
    @type t :: %__MODULE__{turn_id: term(), format: format(), data_b64: String.t()}
  end

  defmodule Interruption do
    @moduledoc "The provider cut the assistant's turn (barge-in)."
    @enforce_keys [:turn_id]
    defstruct [:turn_id]
    @type t :: %__MODULE__{turn_id: term()}
  end

  defmodule ToolCall do
    @moduledoc "The provider asks the session to run a tool; answer with `tool_result/3`."
    @enforce_keys [:call_id, :name, :params]
    defstruct [:call_id, :name, :params]
    @type t :: %__MODULE__{call_id: String.t(), name: String.t(), params: map()}
  end

  defmodule ProviderConversationId do
    @moduledoc "The provider's id for the conversation, emitted as soon as it is known (needed for cleanup)."
    @enforce_keys [:id]
    defstruct [:id]
    @type t :: %__MODULE__{id: String.t()}
  end

  defmodule Closed do
    @moduledoc "The provider conversation ended."
    @enforce_keys [:reason]
    defstruct [:reason]
    @type t :: %__MODULE__{reason: term()}
  end

  defmodule Error do
    @moduledoc """
    The single path for provider failures. `code` is a contract §8 provider code; `message` is
    operator-safe text, never a raw provider frame. Build it with `new/2`.
    """
    @enforce_keys [:code, :message]
    defstruct [:code, :message]

    @codes [:provider_auth, :provider_quota, :provider_unavailable, :provider_error, :privacy_preflight_failed]

    @type code ::
            :provider_auth | :provider_quota | :provider_unavailable | :provider_error | :privacy_preflight_failed
    @type t :: %__MODULE__{code: code(), message: String.t()}

    @spec codes() :: [code()]
    def codes, do: @codes

    @doc """
    An unknown code becomes `:provider_error` (cause-neutral, never a guessed auth or quota
    code). A non-string message is replaced, so a raw provider term cannot reach a client.
    """
    @spec new(term(), term()) :: t()
    def new(code, message) do
      %__MODULE__{
        code: if(code in @codes, do: code, else: :provider_error),
        message: if(is_binary(message), do: message, else: "provider error")
      }
    end
  end

  @all [
    UserTranscript,
    AgentText,
    AgentAudio,
    Interruption,
    ToolCall,
    ProviderConversationId,
    Closed,
    Error
  ]

  @type t ::
          UserTranscript.t()
          | AgentText.t()
          | AgentAudio.t()
          | Interruption.t()
          | ToolCall.t()
          | ProviderConversationId.t()
          | Closed.t()
          | Error.t()

  @doc "Every normalized event module, in contract §4.1 order."
  @spec all() :: [module()]
  def all, do: @all

  @doc "True for a struct of one of the normalized event modules."
  @spec event?(term()) :: boolean()
  def event?(%mod{}), do: mod in @all
  def event?(_), do: false
end
