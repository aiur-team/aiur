defmodule Aiur.BuildOrder.GitHubGraph.Request do
  @moduledoc false

  alias Aiur.GitHub.{Errors, Transport}

  @spec page(map(), String.t(), String.t(), map()) ::
          {:ok, map(), map()} | {:error, atom(), map()}
  def page(%{pages: pages} = state, _token, _query, _variables) when pages >= state.page_budget,
    do: {:error, :page_budget_exhausted, state}

  def page(%{calls: calls} = state, _token, _query, _variables) when calls >= state.call_budget,
    do: {:error, :call_budget_exhausted, state}

  def page(state, token, query, variables) do
    state = %{state | calls: state.calls + 1}

    case Transport.github_graphql_response(state.request_fun, token, query, variables) do
      {:ok, body, response} -> {:ok, body, observe(state, response)}
      {:error, reason, response} -> {:error, reason, observe_failure(state, response)}
    end
  end

  defp observe(state, response), do: %{state | pages: state.pages + 1, rate_limit: observed_rate_limit(state, response)}
  defp observe_failure(state, response), do: %{state | rate_limit: observed_rate_limit(state, response)}
  defp observed_rate_limit(state, response), do: Map.merge(state.rate_limit, Errors.rate_limit_observation(response))
end
