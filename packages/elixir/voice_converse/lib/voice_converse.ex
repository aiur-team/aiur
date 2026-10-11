defmodule VoiceConverse do
  @moduledoc """
  Host-agnostic voice assistant core. Sessions, providers and transports arrive in later tickets;
  this module currently owns the instance supervisor and availability.
  """

  alias VoiceConverse.Config

  @doc "Child spec for one named instance. Raises `ArgumentError` naming the bad field."
  @spec child_spec(keyword() | map() | Config.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    case Config.new(opts) do
      {:ok, %Config{name: name}} ->
        %{
          id: name,
          start: {Supervisor, :start_link, [[], [strategy: :one_for_one, name: name]]},
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
      {:ok, _} -> :ok
      {:error, %{field: field}} -> {:unavailable, {:invalid_config, field}}
    end
  end
end
