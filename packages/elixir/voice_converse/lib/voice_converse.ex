defmodule VoiceConverse do
  @moduledoc """
  Host-agnostic voice assistant core. Sessions, providers and transports arrive in later tickets;
  this module currently owns the instance supervisor and availability.
  """

  alias VoiceConverse.{BootReconciler, Config, ProviderCleanup, SessionRegistry, SessionSupervisor}

  @doc "Child spec for one named instance. Raises `ArgumentError` naming the bad field."
  @spec child_spec(keyword() | map() | Config.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    case Config.new(opts) do
      {:ok, %Config{name: name} = config} ->
        %{
          id: name,
          start: {Supervisor, :start_link, [children(config), [strategy: :one_for_one, name: name]]},
          type: :supervisor
        }

      {:error, %{field: field} = error} ->
        raise ArgumentError, "invalid VoiceConverse config: #{field} (#{inspect(error)})"
    end
  end

  @spec availability(Config.t()) :: :ok | {:unavailable, term()}
  def availability(%Config{} = config) do
    case Config.validate(config) do
      {:ok, %Config{provider: nil}} -> {:unavailable, :no_provider}
      {:ok, config} -> session_availability(config)
      {:error, %{field: field}} -> {:unavailable, {:invalid_config, field}}
    end
  end

  @doc "Starts a conversation in the named VoiceConverse instance."
  @spec start_session(module(), term(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def start_session(instance, target, opts \\ []) do
    SessionSupervisor.start_session(instance, target, opts)
  end

  @doc "Relays an audio chunk to a live conversation."
  @spec push_audio(module(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def push_audio(instance, conversation_id, audio_b64) do
    with {:ok, pid} <- SessionRegistry.lookup(instance, conversation_id) do
      VoiceConverse.Session.push_audio(pid, audio_b64)
    end
  end

  @doc "Ends a live conversation with one stable end reason."
  @spec end_session(module(), String.t(), atom()) :: :ok | {:error, :not_found}
  def end_session(instance, conversation_id, reason \\ :user_end) do
    with {:ok, pid} <- SessionRegistry.lookup(instance, conversation_id) do
      VoiceConverse.Session.end_session(pid, reason)
    end
  end

  @doc "Subscribes a process to conversation events."
  @spec subscribe(module(), String.t(), pid()) :: :ok | {:error, :not_found}
  def subscribe(instance, conversation_id, subscriber \\ self()) do
    with {:ok, pid} <- SessionRegistry.lookup(instance, conversation_id) do
      VoiceConverse.Session.subscribe(pid, subscriber)
    end
  end

  defp session_availability(config) do
    case Config.check_session_start(config) do
      :ok -> :ok
      {:error, %{field: field}} -> {:unavailable, {:not_configured, field}}
    end
  end

  # Startup order is intentional: the durable cleanup queue comes up first, then reconciliation
  # seals any interrupted transcripts and appends cleanup work before later session children may
  # accept a new conversation.
  defp children(%Config{} = config) do
    session_children = [
      {Registry, keys: :unique, name: SessionRegistry.name(config.name)},
      {SessionSupervisor, config}
    ]

    transcript_children(config) ++ session_children
  end

  defp transcript_children(%Config{transcript: :none}), do: []

  defp transcript_children(%Config{transcript: :file, name: name, transcript_root: root, credentials: credentials}) do
    cleanup = Module.concat(name, ProviderCleanup)

    [
      {ProviderCleanup, name: cleanup, transcript_root: root, credentials: {credentials, :elevenlabs}},
      {BootReconciler, transcript_root: root, cleanup: cleanup}
    ]
  end
end
