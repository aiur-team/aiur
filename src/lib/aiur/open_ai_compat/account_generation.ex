defmodule Aiur.OpenAICompat.AccountGeneration do
  @moduledoc false

  alias Aiur.{CodingAgent, ProviderAccountGeneration}
  alias Aiur.ProviderAccountGeneration.Context

  @backend :openai_compat

  @spec new_binding(String.t(), GenServer.server()) :: map()
  def new_binding(backend, server) do
    provider = provider(backend)
    binding = Context.new_binding(provider, @backend, server)

    %{
      account_generation_binding: binding.binding,
      account_generation_authority: binding.authority,
      account_generation_context: binding.context,
      account_generation_topic: binding.topic,
      account_generation_server: server,
      account_generation_provider: provider,
      account_generation_source: trusted_source(provider)
    }
  end

  @spec bind(map()) :: :ok
  def bind(session) do
    with {:ok, server, binding, authority, topic} <- Context.fetch(session),
         provider when is_atom(provider) <- session[:account_generation_provider],
         source when is_atom(source) <- session[:account_generation_source],
         :ok <- recover(server, provider, binding, authority, topic) do
      _ =
        ProviderAccountGeneration.bind(server, provider, @backend, binding,
          source: source,
          auth_mode: "api_key",
          authority: authority
        )
    end

    :ok
  end

  @spec snapshot(map()) :: map()
  def snapshot(session) do
    with {:ok, server, binding, _authority, _topic} <- Context.fetch(session),
         provider when is_atom(provider) <- session[:account_generation_provider] do
      ProviderAccountGeneration.lookup(server, provider, @backend, binding)
    else
      _ -> ProviderAccountGeneration.Snapshot.unavailable(session[:account_generation_provider] || :unknown, @backend)
    end
  end

  @spec process_stopped(map()) :: :ok
  def process_stopped(session) do
    with {:ok, server, binding, authority, topic} <- Context.fetch(session),
         provider when is_atom(provider) <- session[:account_generation_provider],
         source when is_atom(source) <- session[:account_generation_source],
         :ok <- recover(server, provider, binding, authority, topic) do
      _ =
        ProviderAccountGeneration.retire(server, provider, @backend, binding,
          source: source,
          reason: :continuity_lost,
          authority: authority
        )
    end

    case session[:account_generation_provider] do
      provider when is_atom(provider) -> Context.clear(provider, @backend, session)
      _ -> :ok
    end

    :ok
  end

  defp recover(server, provider, binding, authority, topic) do
    ProviderAccountGeneration.recover_binding(server, provider, @backend, %{
      binding: binding,
      authority: authority,
      topic: topic
    })
  end

  defp provider(backend) do
    backend |> CodingAgent.family_for() |> String.to_existing_atom()
  end

  defp trusted_source(provider) do
    provider
    |> CodingAgent.provider_account_generation()
    |> Map.get(:trusted_sources, [])
    |> List.first()
  end
end
