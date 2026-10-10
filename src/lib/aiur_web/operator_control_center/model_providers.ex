defmodule AiurWeb.OperatorControlCenter.ModelProviders do
  @moduledoc """
  Which providers the MODELS pane shows (#3751): only real, accessible credits
  and token allocations.

    * An OpenAI-compatible provider is shown when its credential env resolves
      to a non-empty value — the same "keyed" notion the meter probe uses.
    * A session-authenticated provider (Claude, Codex, Muse) is shown when the
      workflow routes work to it, or when it has a real observation (meter
      windows, named account readings, or a durable last-known standing).

  A configured provider whose data is temporarily unknown stays visible with an
  unknown line (unknown is not zero). A provider with no configured account and
  no observation — a registry placeholder — is not shown at all.
  """

  alias Aiur.CodingAgent
  alias Aiur.Config

  @doc "Keep only the cards for providers with a real, accessible account."
  @spec visible([map()], Enumerable.t()) :: [map()]
  def visible(cards, configured) when is_list(cards), do: Enum.filter(cards, &visible?(&1, configured))

  @doc "Whether one provider card belongs in the MODELS pane."
  @spec visible?(map(), Enumerable.t()) :: boolean()
  def visible?(%{provider: provider} = card, configured) do
    case openai_compat(provider) do
      %{} = compat -> keyed?(compat)
      nil -> provider in configured or observed?(card)
    end
  end

  @doc """
  Provider families the workflow routes work to: every `agent.priority` route,
  the default backend, the usage-limit fallback, and any backend explicitly
  enabled under `agent.backend_configs`. An unreadable config names none, so
  only observed providers show.
  """
  @spec configured_families() :: [atom()]
  def configured_families do
    explicit =
      for {backend, config} <- Config.agent_backend_configs(),
          Map.get(config, "enabled", Map.get(config, :enabled)) == true,
          do: backend

    [Config.agent_kind(), Config.rate_limit_fallback_backend() | Config.agent_priority_backends() ++ explicit]
    |> Enum.flat_map(&family/1)
    |> Enum.uniq()
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp family(backend) when is_binary(backend) do
    case Map.get(CodingAgent.backends(), backend) do
      %{family: family} when is_binary(family) -> [String.to_atom(family)]
      _unknown -> []
    end
  end

  defp family(_backend), do: []

  defp observed?(card) do
    Map.get(card, :windows, []) != [] or
      (get_in(card, [:account_usage, :accounts]) || []) != [] or
      is_map(Map.get(card, :durable_observation))
  end

  defp openai_compat(provider) do
    case get_in(CodingAgent.backends(), [Atom.to_string(provider), :openai_compat]) do
      %{} = compat -> compat
      _other -> nil
    end
  end

  defp keyed?(compat) do
    case Map.get(compat, :management_api_key_env) || Map.get(compat, :api_key_env) do
      env when is_binary(env) and env != "" -> System.get_env(env) not in [nil, ""]
      _missing -> false
    end
  end
end
