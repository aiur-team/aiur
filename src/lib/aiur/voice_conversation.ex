defmodule Aiur.VoiceConversation do
  @moduledoc "Host configuration and lifecycle seam for the read-only Executor voice prototype."

  alias Aiur.Config
  alias Aiur.VoiceConversation.{Credentials, Provider}
  alias Aiur.VoiceConverse.Host.{BriefingSource, CommandSource}

  @instance Aiur.VoiceConversation.Instance
  @limit_keys [:max_session_seconds, :idle_timeout_seconds, :daily_minutes_cap, :context_token_budget]

  @spec instance() :: module()
  def instance, do: @instance

  @spec config() :: {:ok, VoiceConverse.Config.t()} | {:error, term()}
  def config do
    with {:ok, root} <- Config.Paths.conversation_state_dir() do
      build_config(Config.voice_conversation(), Path.join(root, "voice"))
    end
  end

  @doc "Maps resolved host settings without fetching or retaining a credential."
  @spec build_config(map(), Path.t()) :: {:ok, VoiceConverse.Config.t()} | {:error, term()}
  def build_config(settings, transcript_root) do
    VoiceConverse.Config.new(
      name: @instance,
      provider: provider(settings),
      credentials: Credentials,
      briefing_source: BriefingSource,
      command_source: CommandSource,
      transcript_root: transcript_root,
      llm: settings.llm,
      cloud_disclosure_accepted: settings.cloud_disclosure_accepted,
      roles_dir: settings.roles_dir,
      limits: Map.take(settings, @limit_keys),
      allowed_tools: ["get_status", "get_details", "record_summary", "end_conversation"]
    )
  end

  @spec child_specs() :: [Supervisor.child_spec() | {module(), term()}]
  def child_specs do
    case config() do
      {:ok, config} -> [{VoiceConverse, config}]
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
    with {:ok, config} <- config(),
         provider when not is_nil(provider) <- Keyword.get(opts, :provider, config.provider),
         {:ok, :present} <- Credentials.fetch(provider_id(provider), :probe) do
      VoiceConverse.start_session(@instance, :executor, Keyword.put(opts, :client, owner))
    else
      _ -> {:error, :unconfigured}
    end
  end

  @spec push_audio(String.t(), String.t()) :: :ok | {:error, :not_found}
  def push_audio(id, audio), do: VoiceConverse.push_audio(@instance, id, audio)

  @spec end_session(String.t(), atom()) :: :ok | {:error, :not_found}
  def end_session(id, reason \\ :user_end), do: VoiceConverse.end_session(@instance, id, reason)

  defp provider(%{provider: :openai_realtime} = settings),
    do: {Aiur.VoiceConversation.OpenAIProvider, [voice_id: settings.voice_id]}

  defp provider(%{agent_id: nil}), do: nil
  defp provider(%{agent_id: agent_id}), do: {Provider, [agent_id: agent_id]}

  defp provider_id({module, _opts}), do: module.descriptor().id
  defp provider_id(module), do: module.descriptor().id
end
