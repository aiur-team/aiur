defmodule VoiceConverse.Provider do
  @moduledoc """
  Conversation provider behaviour (voice-session contract §4, Conversation role). The adapter owns
  only the provider connection; the session owns every decision.

  After `open/1`, the adapter sends `{:voice_conversation, ref, event}` to `spec.owner`, where
  `event` is a `VoiceConverse.Events` struct. Nothing else reaches the owner.

  Credentials: `spec.credentials` is `{credentials_module, provider_id}`. The adapter calls
  `credentials_module.fetch(provider_id, :connect)` while connecting and keeps the secret in
  neither the spec nor its state.
  """

  alias VoiceConverse.Events

  @type ref :: term()
  @type tool_spec :: %{name: String.t(), description: String.t(), parameters: map()}

  @type session_spec :: %{
          required(:owner) => pid(),
          required(:credentials) => {module(), provider_id :: atom()},
          required(:system_prompt) => String.t(),
          required(:first_message) => String.t() | nil,
          required(:context) => String.t(),
          required(:tools) => [tool_spec()],
          required(:audio_in) => :pcm_16000,
          required(:audio_out) => Events.AgentAudio.format(),
          optional(:voice_id) => String.t(),
          optional(:llm) => String.t(),
          optional(atom()) => term()
        }

  @typedoc """
  `:events` lists the `VoiceConverse.Events` modules this provider can emit; the session degrades
  for the rest (no `Interruption` means the provider cannot cut playback). `:client_parts` are
  parts the client runs itself. `manual_truncation: true` means the session calls `truncate/3`
  after an interruption.
  """
  @type capabilities :: %{
          required(:events) => [module()],
          required(:text_only?) => boolean(),
          optional(:client_parts) => [:browser_stt | :browser_tts | :text_in],
          optional(:manual_truncation) => boolean()
        }

  @typedoc "Registry facts (MP-E6-C14-T01): what the option is and what it needs."
  @type descriptor :: %{
          required(:id) => atom(),
          required(:family) => :speech_to_speech | :hosted_agent | :cascade | :agent_native,
          required(:label) => String.t(),
          required(:modes) => [:voice | :text],
          required(:needs) => [atom()],
          optional(:parts) => %{stt: term(), llm: term(), tts: term()},
          optional(:client_parts) => [:browser_stt | :browser_tts | :text_in],
          optional(:privacy) => map(),
          optional(:price_hint) => term()
        }

  @callback descriptor() :: descriptor()
  @callback capabilities() :: capabilities()

  @doc "Provider privacy check; the core calls it before `open/1`."
  @callback preflight(session_spec()) :: :ok | {:error, Events.Error.t()}

  @callback open(session_spec()) :: {:ok, ref()} | {:error, Events.Error.t()}
  @callback push_audio(ref(), base64_pcm :: String.t()) :: :ok

  @doc "Adds context without interrupting the current turn."
  @callback send_context(ref(), text :: String.t()) :: :ok
  @callback send_user_text(ref(), text :: String.t()) :: :ok
  @callback tool_result(ref(), call_id :: String.t(), result :: String.t()) :: :ok

  @doc "Speaks a host-originated line at the next pause (`when: :idle`) or now (`when: :now`)."
  @callback announce(ref(), text :: String.t(), opts :: [when: :idle | :now]) :: :ok

  @doc "Tells the provider how much of a turn was heard; only for `manual_truncation: true`."
  @callback truncate(ref(), turn_id :: term(), played_until_ms :: non_neg_integer()) :: :ok
  @callback close(ref()) :: :ok

  @optional_callbacks preflight: 1, announce: 3, truncate: 3
end
