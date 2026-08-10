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
      {:ok, body, response} -> {:ok, body, observe(state, body, response)}
      {:error, reason, response} -> {:error, reason, observe_failure(state, response)}
    end
  end

  defp observe(state, body, response) do
    %{
      state
      | pages: state.pages + 1,
        rate_limit: Map.merge(observed_rate_limit(state, response), query_cost(body, state.rate_limit))
    }
  end

  defp observe_failure(state, response), do: %{state | rate_limit: observed_rate_limit(state, response)}
  defp observed_rate_limit(state, response), do: Map.merge(state.rate_limit, Errors.rate_limit_observation(response))

  # The response headers report the balance left in the GraphQL points budget
  # but never what the call just spent, so a query's cost was unobservable
  # (#1766). Only the body's `rateLimit` block reports it.
  #
  # `cost` accumulates over the read's pages: a read spends points per page, and
  # the operationally useful figure is what the whole read cost, since that is
  # what multiplies by the poll frequency into a per-hour number. The balance
  # fields describe the latest call, and the body's balance supersedes the
  # header's so it agrees with the cost reported beside it.
  defp query_cost(%{"data" => %{"rateLimit" => %{} = rate_limit}}, previous) do
    %{
      cost: accumulated_cost(previous, rate_limit["cost"]),
      remaining: rate_limit["remaining"],
      limit: rate_limit["limit"]
    }
    |> Enum.filter(fn {_key, value} -> is_integer(value) and value >= 0 end)
    |> Map.new()
    |> put_reset_at(rate_limit["resetAt"])
  end

  defp query_cost(_body, _previous), do: %{}

  defp accumulated_cost(%{cost: spent}, cost) when is_integer(spent) and spent >= 0 and is_integer(cost) and cost >= 0,
    do: spent + cost

  defp accumulated_cost(_previous, cost) when is_integer(cost) and cost >= 0, do: cost
  defp accumulated_cost(previous, _cost), do: Map.get(previous, :cost)

  defp put_reset_at(observation, reset_at) when is_binary(reset_at), do: Map.put(observation, :reset_at, reset_at)
  defp put_reset_at(observation, _reset_at), do: observation
end
