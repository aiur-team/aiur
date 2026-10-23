defmodule VoiceConverse.Config do
  @moduledoc """
  Validated configuration for one VoiceConverse instance. The core reads no application env.

  `llm` and `cloud_disclosure_accepted` have no default: the operator must choose the model and
  accept that audio and text go to a cloud provider. An instance still boots without them, but
  `check_session_start/1` refuses a session until both are set.

  `limits.daily_minutes_cap` is an integer number of minutes (0 disables sessions) or `nil` for
  no cap. Minutes from a session that ended in a crash always count toward the cap.
  """

  @required [:transcript_root, :credentials, :briefing_source]
  @ports [:credentials, :briefing_source, :agent_channel, :command_source, :token_issuer]

  @default_limits %{
    max_session_seconds: 1_800,
    idle_timeout_seconds: 120,
    daily_minutes_cap: 60,
    context_token_budget: 4_000,
    briefing_token_budget: 1_500,
    max_sessions: 1,
    consult_timeout_seconds: 300
  }
  @default_turn %{interruptions: true, eagerness: :normal, turn_timeout_seconds: 10}

  defstruct name: VoiceConverse,
            provider: nil,
            llm: nil,
            cloud_disclosure_accepted: nil,
            credentials: nil,
            briefing_source: nil,
            agent_channel: nil,
            command_source: nil,
            token_issuer: nil,
            transcript_root: nil,
            transcript: :file,
            redactor: &VoiceConverse.Redact.redact/1,
            roles: [],
            roles_dir: nil,
            glossary: [],
            limits: @default_limits,
            turn: @default_turn,
            privacy: %{}

  @type t :: %__MODULE__{}

  @doc "Default `limits`, for hosts that map their own settings onto them."
  @spec default_limits() :: map()
  def default_limits, do: @default_limits

  @doc "Builds and validates a config from a keyword list or map."
  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, %{field: atom(), reason: atom()}}
  def new(%__MODULE__{} = config), do: validate(config)

  def new(opts) do
    opts = Map.new(opts)

    with {:ok, opts} <- check_known(opts) do
      base = struct(__MODULE__, Map.drop(opts, [:limits, :turn]))

      validate(%{
        base
        | limits: Map.merge(@default_limits, Map.new(opts[:limits] || %{})),
          turn: Map.merge(@default_turn, Map.new(opts[:turn] || %{}))
      })
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, %{field: atom(), reason: atom()}}
  def validate(%__MODULE__{} = config) do
    with :ok <- check_required(config),
         :ok <- check_ports(config),
         :ok <- check_transcript_root(config),
         :ok <- check_session_settings(config),
         :ok <- check_limits(config),
         :ok <- VoiceConverse.ProviderPolicy.validate(config.privacy) do
      {:ok, config}
    end
  end

  @doc """
  Checks the settings a session needs before it may start: an `llm` and an explicit `true` for
  `cloud_disclosure_accepted`. The error names the missing field.
  """
  @spec check_session_start(t()) :: :ok | {:error, %{field: atom(), reason: atom()}}
  def check_session_start(%__MODULE__{llm: llm} = config) do
    if is_nil(llm) or String.trim(llm) == "",
      do: {:error, %{field: :llm, reason: :missing}},
      else: check_disclosure(config)
  end

  defp check_disclosure(%__MODULE__{cloud_disclosure_accepted: nil}),
    do: {:error, %{field: :cloud_disclosure_accepted, reason: :missing}}

  defp check_disclosure(%__MODULE__{cloud_disclosure_accepted: true}), do: :ok

  defp check_disclosure(%__MODULE__{}),
    do: {:error, %{field: :cloud_disclosure_accepted, reason: :not_accepted}}

  defp check_known(opts) do
    case Enum.find(Map.keys(opts), &(not Map.has_key?(%__MODULE__{}, &1))) do
      nil -> {:ok, opts}
      field -> {:error, %{field: field, reason: :unknown}}
    end
  end

  defp check_required(config) do
    with :ok <- check_transcript_mode(config) do
      case Enum.find(required_fields(config), &(Map.fetch!(config, &1) in [nil, ""])) do
        nil -> :ok
        field -> {:error, %{field: field, reason: :missing}}
      end
    end
  end

  # Checked first so a typo reports `transcript` itself, and refused rather than read as either mode.
  defp check_transcript_mode(%{transcript: mode}) when mode in [:file, :none], do: :ok
  defp check_transcript_mode(_config), do: {:error, %{field: :transcript, reason: :invalid}}

  # `transcript: :none` stores no transcript, so it needs no root.
  defp required_fields(%{transcript: :none}), do: @required -- [:transcript_root]
  defp required_fields(_config), do: @required

  defp check_ports(config) do
    case Enum.find(@ports, &(not valid_port?(Map.fetch!(config, &1)))) do
      nil -> :ok
      field -> {:error, %{field: field, reason: :invalid}}
    end
  end

  defp valid_port?(nil), do: true
  defp valid_port?(mod), do: is_atom(mod)

  # A no-transcript config carries no root, so nothing downstream has a place to write.
  defp check_transcript_root(%{transcript: :none, transcript_root: nil}), do: :ok

  defp check_transcript_root(%{transcript: :none}),
    do: {:error, %{field: :transcript_root, reason: :not_allowed}}

  defp check_transcript_root(%{transcript_root: root}) when is_binary(root), do: :ok
  defp check_transcript_root(_), do: {:error, %{field: :transcript_root, reason: :invalid}}

  defp check_session_settings(%{llm: llm}) when not (is_nil(llm) or is_binary(llm)),
    do: {:error, %{field: :llm, reason: :invalid}}

  defp check_session_settings(%{cloud_disclosure_accepted: accepted})
       when not (is_nil(accepted) or is_boolean(accepted)),
       do: {:error, %{field: :cloud_disclosure_accepted, reason: :invalid}}

  defp check_session_settings(_config), do: :ok

  defp check_limits(%{limits: limits}) do
    case Enum.find(limits, fn {key, value} -> not valid_limit?(key, value) end) do
      nil -> :ok
      {key, _} -> {:error, %{field: :limits, reason: :invalid, key: key}}
    end
  end

  defp valid_limit?(:daily_minutes_cap, nil), do: true
  defp valid_limit?(:daily_minutes_cap, value), do: is_integer(value) and value >= 0
  defp valid_limit?(_key, value), do: is_integer(value) and value > 0
end
