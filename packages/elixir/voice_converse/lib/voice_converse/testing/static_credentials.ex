defmodule VoiceConverse.Testing.StaticCredentials do
  @moduledoc """
  Test credentials backed by `:persistent_term`; call `put/1` with `%{provider => secret}` in test setup.

  `fetch/2` returns `{:ok, :present}` only for `:probe`; every credential-use purpose returns the
  stored secret binary. This makes it safe to use as the presence-only registry port while keeping
  connection, render, and deletion callers compatible with the credentials contract.
  """
  @behaviour VoiceConverse.Ports.Credentials

  @key {__MODULE__, :secrets}

  @spec put(%{atom() => String.t()}, keyword()) :: :ok
  def put(secrets, opts \\ []) do
    :persistent_term.put(@key, %{secrets: secrets, observer: Keyword.get(opts, :observer)})
  end

  @impl true
  def fetch(provider, purpose) do
    %{secrets: secrets, observer: observer} = stored_credentials()
    if is_pid(observer), do: send(observer, {__MODULE__, :fetch, provider, purpose})

    case Map.fetch(secrets, provider) do
      {:ok, _secret} when purpose == :probe -> {:ok, :present}
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, :missing}
    end
  end

  defp stored_credentials do
    case :persistent_term.get(@key, %{}) do
      %{secrets: _secrets, observer: _observer} = stored -> stored
      secrets -> %{secrets: secrets, observer: nil}
    end
  end
end
