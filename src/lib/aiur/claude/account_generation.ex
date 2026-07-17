defmodule Aiur.Claude.AccountGeneration do
  @moduledoc false

  alias Aiur.Claude.AccountGeneration.Context
  alias Aiur.ProviderAccountGeneration

  @auth_modes [:subscription, :api_key]

  @spec new_binding(GenServer.server()) :: map()
  def new_binding(server \\ ProviderAccountGeneration), do: Context.new_binding(server)

  @spec observe(map(), :subscription | :api_key | :unknown) :: {:ok, reference()} | {:error, atom()}
  def observe(session, auth_mode) when auth_mode in @auth_modes do
    with {:ok, server, binding, authority, topic} <- Context.fetch(session),
         :ok <- recover_retained_binding(server, binding, authority, topic),
         {:ok, %{generation: generation, freshness: :current, health: :healthy}} when is_binary(generation) <-
           transition(server, binding, authority, Context.auth_mode(session), auth_mode) do
      Context.put_auth_mode(session, auth_mode)
      {:ok, binding}
    else
      _ -> {:error, :unknown_account_generation}
    end
  end

  def observe(session, :unknown) when is_map(session) do
    lose_continuity(session, :untrusted_lifecycle)
    {:error, :unknown_account_generation}
  end

  def observe(_session, _auth_mode), do: {:error, :unknown_account_generation}

  @spec trusted_binding(map()) :: {:ok, reference()} | :error
  def trusted_binding(session) do
    with {:ok, server, binding, authority, topic} <- Context.fetch(session),
         :ok <- recover_retained_binding(server, binding, authority, topic),
         %{generation: generation, freshness: :current, health: :healthy} when is_binary(generation) <-
           ProviderAccountGeneration.lookup(server, :claude, :app_server, binding) do
      {:ok, binding}
    else
      _ -> :error
    end
  end

  @spec process_stopped(map()) :: :ok
  def process_stopped(session) when is_map(session) do
    retire_binding(session, :continuity_lost)
    Context.clear(session)
    :ok
  end

  def process_stopped(_session), do: :ok

  defp transition(server, binding, authority, nil, auth_mode) do
    ProviderAccountGeneration.bind(server, :claude, :app_server, binding,
      source: :claude_app_server,
      auth_mode: Atom.to_string(auth_mode),
      authority: authority
    )
  end

  defp transition(server, binding, authority, auth_mode, auth_mode) do
    case ProviderAccountGeneration.lookup(server, :claude, :app_server, binding) do
      %{generation: generation, freshness: :current, health: :healthy} when is_binary(generation) ->
        ProviderAccountGeneration.confirm(server, :claude, :app_server, binding,
          source: :claude_app_server,
          auth_mode: Atom.to_string(auth_mode),
          authority: authority
        )

      _unknown ->
        ProviderAccountGeneration.bind(server, :claude, :app_server, binding,
          source: :claude_app_server,
          auth_mode: Atom.to_string(auth_mode),
          authority: authority
        )
    end
  end

  defp transition(server, binding, authority, _previous, auth_mode) do
    ProviderAccountGeneration.replace(server, :claude, :app_server, binding,
      source: :claude_app_server,
      auth_mode: Atom.to_string(auth_mode),
      authority: authority
    )
  end

  defp lose_continuity(session, reason) do
    with {:ok, server, binding, authority, topic} <- Context.fetch(session),
         :ok <- recover_retained_binding(server, binding, authority, topic) do
      ProviderAccountGeneration.invalidate(server, :claude, :app_server, binding,
        source: :claude_app_server,
        reason: reason,
        authority: authority
      )
    end

    Context.clear_auth_mode(session)
    :ok
  end

  defp retire_binding(session, reason) do
    with {:ok, server, binding, authority, topic} <- Context.fetch(session),
         :ok <- recover_retained_binding(server, binding, authority, topic) do
      ProviderAccountGeneration.retire(server, :claude, :app_server, binding,
        source: :claude_app_server,
        reason: reason,
        authority: authority
      )
    end

    :ok
  end

  defp recover_retained_binding(server, binding, authority, topic) do
    ProviderAccountGeneration.recover_binding(server, :claude, :app_server, %{
      binding: binding,
      authority: authority,
      topic: topic
    })
  end
end
