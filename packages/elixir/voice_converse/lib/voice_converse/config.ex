defmodule VoiceConverse.Config do
  @moduledoc "Validated configuration for one VoiceConverse instance. The core reads no application env."

  @required [:transcript_root, :credentials, :briefing_source]
  @ports [:credentials, :briefing_source, :agent_channel, :command_source]

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
            credentials: nil,
            briefing_source: nil,
            agent_channel: nil,
            command_source: nil,
            transcript_root: nil,
            redactor: &VoiceConverse.Redact.redact/1,
            roles: [],
            roles_dir: nil,
            glossary: [],
            limits: @default_limits,
            turn: @default_turn,
            privacy: %{}

  @type t :: %__MODULE__{}

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
         :ok <- check_limits(config) do
      {:ok, config}
    end
  end

  defp check_known(opts) do
    case Enum.find(Map.keys(opts), &(not Map.has_key?(%__MODULE__{}, &1))) do
      nil -> {:ok, opts}
      field -> {:error, %{field: field, reason: :unknown}}
    end
  end

  defp check_required(config) do
    case Enum.find(@required, &(Map.fetch!(config, &1) in [nil, ""])) do
      nil -> :ok
      field -> {:error, %{field: field, reason: :missing}}
    end
  end

  defp check_ports(config) do
    case Enum.find(@ports, &(not valid_port?(Map.fetch!(config, &1)))) do
      nil -> :ok
      field -> {:error, %{field: field, reason: :invalid}}
    end
  end

  defp valid_port?(nil), do: true
  defp valid_port?(mod), do: is_atom(mod)

  defp check_transcript_root(%{transcript_root: root}) when is_binary(root), do: :ok
  defp check_transcript_root(_), do: {:error, %{field: :transcript_root, reason: :invalid}}

  defp check_limits(%{limits: limits}) do
    case Enum.find(limits, fn {_k, v} -> not (is_integer(v) and v > 0) end) do
      nil -> :ok
      {key, _} -> {:error, %{field: :limits, reason: :invalid, key: key}}
    end
  end
end
