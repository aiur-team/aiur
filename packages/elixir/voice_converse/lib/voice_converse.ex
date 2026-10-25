defmodule VoiceConverse do
  @moduledoc """
  Host-agnostic voice assistant core. Sessions, providers and transports arrive in later tickets;
  this module currently owns the instance supervisor and availability.
  """

  alias VoiceConverse.{BootReconciler, Config, ProviderCleanup}

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

  defp session_availability(config) do
    case Config.check_session_start(config) do
      :ok -> :ok
      {:error, %{field: field}} -> {:unavailable, {:not_configured, field}}
    end
  end

  # Startup order is intentional: the durable cleanup queue comes up first, then reconciliation
  # seals any interrupted transcripts and appends cleanup work before later session children may
  # accept a new conversation.
  defp children(%Config{transcript: :none}), do: []

  defp children(%Config{transcript: :file, name: name, transcript_root: root, credentials: credentials}) do
    cleanup = Module.concat(name, ProviderCleanup)

    [
      {ProviderCleanup, name: cleanup, transcript_root: root, credentials: {credentials, :elevenlabs}},
      {BootReconciler, transcript_root: root, cleanup: cleanup}
    ]
  end
end
