defmodule Aiur.GitHub.Transport.GraphQL do
  @moduledoc """
  GraphQL request pricing, instrumentation and response validation.

  Transport keeps the public entry points; this module preserves the decoded
  and raw response contracts, including held, unknown and partial outcomes.
  """

  alias Aiur.GitHub.Access.Settings
  alias Aiur.GitHub.{Errors, GraphQLCost, Transport}

  require Logger

  @spec github_graphql(function(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def github_graphql(request_fun, token, query, variables, opts \\ []) do
    case github_graphql_response(request_fun, token, query, variables, opts) do
      {:ok, body, response} ->
        Transport.log_rate_budget_pressure(response)
        {:ok, body}

      {:error, :invalid_graphql_response, _response} ->
        {:error, :invalid_graphql_response}

      {:error, _reason, %{status: 200, body: %{"errors" => errors}}} when is_list(errors) ->
        {:error, {:github_graphql_errors, errors}}

      {:error, {:github, _classification, _detail}, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason, _response} ->
        {:error, reason}
    end
  end

  @doc """
  Issues a GraphQL request and returns the decoded body beside the raw response.

  Three things happen here that no call site has to remember.

  The document is priced before it is sent. `Aiur.GitHub.GraphQLCost.check/2`
  refuses a fan-out whose *shape* has gone pathological with
  `{:error, {:graphql_cost_ceiling, details}}`, so such a query fails at the
  call site instead of being discovered in the ranking an hour later. The
  ceiling sits far above every document this tree sends — the estimate is a node
  count and GitHub bills these documents dramatically cheaper — so it never
  fires on real traffic.

  The query is passed through `Aiur.GitHub.GraphQLCost.instrument/1`, which adds
  a `rateLimit { cost }` selection where the document does not already carry
  one. That selection resolves on the `Query` root the request was already
  paying for, so it adds no request and no point — and without it the response
  reports only the balance left, never what this call spent. Every GraphQL path
  but the Build Order graph was consequently being counted at one point.

  The request is stamped with `opts[:caller]`, the call site to bill. It is
  declared rather than inferred because the batch queries make inference wrong:
  `CommentPollBatch` names 33 tickets in one document and belongs to none of
  them. A call site that declares nothing falls back to the operation name.
  """
  @spec github_graphql_response(function(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map(), map()} | {:error, term(), map() | nil}
  def github_graphql_response(request_fun, token, query, variables, opts \\ []) do
    case GraphQLCost.check(query, caller: Keyword.get(opts, :caller)) do
      :ok -> send_graphql(request_fun, token, query, variables, opts)
      {:error, {:graphql_cost_ceiling, details}} -> refuse_over_budget_graphql(details)
    end
  end

  defp send_graphql(request_fun, token, query, variables, opts) do
    Settings.with_request(fn ->
      body = %{"query" => GraphQLCost.instrument(query), "variables" => variables}

      request =
        %{method: :post, url: Transport.graphql_url(), token: token, body: body}
        |> maybe_put_max_response_bytes(opts)
        |> maybe_put_caller(opts)

      validate_graphql_response(request_fun.(request))
    end)
  end

  # The budget is the reason the call is refused, so the refusal has to be
  # louder than the spend it prevents: a document this size is a bug in the
  # query, not a transient condition to retry around.
  defp refuse_over_budget_graphql(details) do
    Logger.warning(
      "Github GraphQL cost ceiling: operation=#{details.operation} caller=#{details.caller || "undeclared"} " <>
        "points=#{details.points} ceiling=#{details.ceiling_points} nodes=#{details.nodes}"
    )

    {:error, {:graphql_cost_ceiling, details}, nil}
  end

  defp maybe_put_caller(request, opts), do: Transport.put_caller(request, opts)

  defp maybe_put_max_response_bytes(request, opts) do
    case Keyword.get(opts, :max_response_bytes) do
      limit when is_integer(limit) and limit > 0 -> Map.put(request, :max_response_bytes, limit)
      _limit -> request
    end
  end

  defp validate_graphql_response({:ok, response}), do: validate_graphql_http_response(response)
  defp validate_graphql_response({:error, {:aiur, :locally_held, _hold} = reason}), do: {:error, reason, nil}
  defp validate_graphql_response({:error, reason}), do: {:error, Errors.classify_error({:error, reason}), nil}
  defp validate_graphql_response(_response), do: {:error, :invalid_graphql_response, nil}

  defp validate_graphql_http_response(%{private: %{aiur_response_too_large: true}} = response),
    do: {:error, :github_graphql_response_too_large, response}

  defp validate_graphql_http_response(%{status: 200} = response), do: validate_graphql_success(response)

  defp validate_graphql_http_response(%{status: status} = response)
       when is_integer(status) and status in 100..599 do
    {:error, Errors.github_graph_status_error(response), response}
  end

  defp validate_graphql_http_response(%{} = response), do: {:error, :invalid_graphql_response, response}
  defp validate_graphql_http_response(_response), do: {:error, :invalid_graphql_response, nil}

  defp validate_graphql_success(%{body: %{"errors" => errors}} = response) do
    if valid_graphql_errors?(errors),
      do: {:error, Errors.graphql_error(response), response},
      else: {:error, :invalid_graphql_response, response}
  end

  defp validate_graphql_success(%{body: body} = response) when is_map(body), do: {:ok, body, response}
  defp validate_graphql_success(response), do: {:error, :invalid_graphql_response, response}

  defp valid_graphql_errors?(errors) when is_list(errors) and errors != [], do: Enum.all?(errors, &is_map/1)
  defp valid_graphql_errors?(_errors), do: false
end
