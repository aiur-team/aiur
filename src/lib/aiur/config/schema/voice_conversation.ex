defmodule Aiur.Config.Schema.VoiceConversation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @fields [
    :agent_id,
    :llm,
    :cloud_disclosure_accepted,
    :roles_dir,
    :max_session_seconds,
    :idle_timeout_seconds,
    :daily_minutes_cap,
    :context_token_budget
  ]

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-voice-00 voice.conversation.agent_id
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail voice.conversation.agent_id | string or nil | nil | ElevenLabs Agents agent the assistant talks through. An account-visible id, not a secret. |
    field(:agent_id, :string)
    # No default on purpose: the operator chooses the model (E6-OQ7).
    # @config-reference config-configuration-voice-00 voice.conversation.llm
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail voice.conversation.llm | string or nil | nil (required) | Model the assistant reasons with. No default: a voice session refuses to start until it is set. |
    field(:llm, :string)
    # No default on purpose: nil means the operator has not answered (E6-OQ7).
    # @config-reference config-configuration-voice-00 voice.conversation.cloud_disclosure_accepted
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail voice.conversation.cloud_disclosure_accepted | boolean or nil | nil (required) | Set `true` to accept that conversation audio and text go to the cloud voice provider. A session refuses to start until it is `true`. |
    field(:cloud_disclosure_accepted, :boolean)
    # @config-reference config-configuration-voice-00 voice.conversation.roles_dir
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail voice.conversation.roles_dir | string or nil | nil | Directory of role pre-context files. A relative path resolves against the config file's directory, like `prompt_file`. |
    field(:roles_dir, :string)
    # @config-reference config-configuration-voice-00 voice.conversation.max_session_seconds
    # @config-detail voice.conversation.max_session_seconds | integer | 1800 | Longest one voice session may run, 60 to 3600 seconds. |
    field(:max_session_seconds, :integer, default: 1_800)
    # @config-reference config-configuration-voice-00 voice.conversation.idle_timeout_seconds
    # @config-detail voice.conversation.idle_timeout_seconds | integer | 120 | Silence after which a session ends, 15 to 900 seconds. |
    field(:idle_timeout_seconds, :integer, default: 120)
    # Proposed default pending the owner decision (E6-OQ6); operators may change it.
    # @config-reference config-configuration-voice-00 voice.conversation.daily_minutes_cap
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail voice.conversation.daily_minutes_cap | integer or nil | 60 | Voice minutes allowed per day. Minutes from crashed sessions always count. `0` disables sessions; an explicit `null` removes the cap. |
    field(:daily_minutes_cap, :integer, default: 60)
    # @config-reference config-configuration-voice-00 voice.conversation.context_token_budget
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail voice.conversation.context_token_budget | integer | 4000 | Token budget for the context handed to the assistant, 1000 to 32000. |
    field(:context_token_budget, :integer, default: 4_000)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, @fields, empty_values: [])
    |> validate_not_blank(:agent_id)
    |> validate_not_blank(:llm)
    |> validate_not_blank(:roles_dir)
    |> validate_number(:max_session_seconds, greater_than_or_equal_to: 60, less_than_or_equal_to: 3_600)
    |> validate_number(:idle_timeout_seconds, greater_than_or_equal_to: 15, less_than_or_equal_to: 900)
    |> validate_number(:daily_minutes_cap, greater_than_or_equal_to: 0)
    |> validate_number(:context_token_budget, greater_than_or_equal_to: 1_000, less_than_or_equal_to: 32_000)
  end

  @doc "Resolves a relative `roles_dir` against the directory of `config_path`, like `prompt_file`."
  @spec resolve_roles_dir(t(), Path.t()) :: t()
  def resolve_roles_dir(%__MODULE__{roles_dir: nil} = settings, _config_path), do: settings

  def resolve_roles_dir(%__MODULE__{roles_dir: dir} = settings, config_path),
    do: %{settings | roles_dir: Path.expand(dir, Path.dirname(config_path))}

  defp validate_not_blank(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if String.trim(value) == "", do: [{field, "must not be blank"}], else: []
    end)
  end
end
