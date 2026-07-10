defmodule Aiur.Codex.DynamicTool.LinearGraphQL do
  @moduledoc """
  Dynamic tool handler for the `linear_graphql` tool.
  """

  @behaviour Aiur.Codex.DynamicTool.Handler

  alias Aiur.Codex.DynamicTool.Errors
  alias Aiur.Codex.DynamicTool.Response
  alias Aiur.Linear.Client, as: LinearClient

  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Aiur's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @impl true
  @spec tools() :: [String.t()]
  def tools, do: ["linear_graphql"]

  @impl true
  @spec specs() :: [map()]
  def specs do
    [
      %{
        "name" => "linear_graphql",
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]
  end

  @impl true
  @spec execute(String.t(), term(), keyword()) :: map()
  def execute("linear_graphql", arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &LinearClient.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        Response.failure(Errors.payload(reason))
    end
  end

  @spec normalize_linear_graphql_arguments(term()) ::
          {:ok, String.t(), map()} | {:error, atom()}
  def normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  def normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  @spec normalize_query(map()) :: {:ok, String.t()} | {:error, atom()}
  def normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  @spec normalize_variables(map()) :: {:ok, map()} | {:error, atom()}
  def normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  @spec graphql_response(term()) :: map()
  def graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    Response.build(success, Response.encode_payload(response))
  end
end
