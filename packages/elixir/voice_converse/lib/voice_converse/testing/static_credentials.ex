defmodule VoiceConverse.Testing.StaticCredentials do
  @moduledoc "Test credentials backed by `:persistent_term`; call `put/1` with `%{provider => secret}` in test setup."
  @behaviour VoiceConverse.Ports.Credentials

  @key {__MODULE__, :secrets}

  @spec put(%{atom() => String.t()}) :: :ok
  def put(secrets), do: :persistent_term.put(@key, secrets)

  @impl true
  def fetch(provider, _purpose) do
    case Map.fetch(:persistent_term.get(@key, %{}), provider) do
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, :missing}
    end
  end
end
