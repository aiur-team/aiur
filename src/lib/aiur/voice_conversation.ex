defmodule Aiur.VoiceConversation do
  @moduledoc "Host configuration and lifecycle seam for the read-only Executor voice prototype."

  alias Aiur.Config
  alias Aiur.VoiceConversation.Credentials
  alias Aiur.VoiceConverse.Host.Config, as: HostConfig

  @instance Aiur.VoiceConversation.Instance

  @spec instance() :: module()
  def instance, do: @instance

  @spec config() :: {:ok, VoiceConverse.Config.t()} | {:error, term()}
  def config do
    HostConfig.build(Config.voice_conversation())
  end

  @doc "Maps resolved host settings without fetching or retaining a credential."
  @spec build_config(map(), Path.t()) :: {:ok, VoiceConverse.Config.t()} | {:error, term()}
  defdelegate build_config(settings, transcript_root), to: HostConfig, as: :build

  @spec child_specs() :: [Supervisor.child_spec() | {module(), term()}]
  def child_specs do
    case config() do
      {:ok, %{provider: nil}} -> []
      {:ok, config} -> [Aiur.VoiceConverse.Host.Telemetry, {VoiceConverse, config}]
      {:error, reason} -> raise ArgumentError, "invalid voice conversation configuration: #{inspect(reason)}"
    end
  end

  @spec availability() :: :ok | {:unavailable, term()}
  def availability do
    with {:ok, config} <- config(),
         :ok <- VoiceConverse.availability(config),
         {:ok, :present} <- Credentials.fetch(provider_id(config.provider), :probe) do
      :ok
    else
      {:error, :missing} -> {:unavailable, :missing_credentials}
      {:error, reason} -> {:unavailable, reason}
      unavailable -> unavailable
    end
  end

  @spec start_session(pid(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_session(owner, opts \\ []) when is_pid(owner) do
    case availability() do
      :ok -> VoiceConverse.start_session(@instance, :executor, Keyword.put(opts, :client, owner))
      {:unavailable, reason} -> {:error, reason}
    end
  end

  @spec push_audio(String.t(), String.t()) :: :ok | {:error, :not_found}
  def push_audio(id, audio), do: VoiceConverse.push_audio(@instance, id, audio)

  @spec end_session(String.t(), atom()) :: :ok | {:error, :not_found}
  def end_session(id, reason \\ :user_end), do: VoiceConverse.end_session(@instance, id, reason)

  defp provider_id({module, _opts}), do: module.descriptor().id
  defp provider_id(module), do: module.descriptor().id
end
