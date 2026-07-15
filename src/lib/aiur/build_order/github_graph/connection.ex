defmodule Aiur.BuildOrder.GitHubGraph.Connection do
  @moduledoc false

  @type page_info :: %{has_next?: boolean(), end_cursor: String.t() | nil}
  @type parsed :: {:ok, [map()], non_neg_integer(), page_info()} | {:error, :invalid_connection}

  @spec catalog(term()) :: {:ok, map()} | {:error, :invalid_connection}
  def catalog(body), do: body |> nested_value(["data", "repository", "issues"]) |> value()

  @spec selected(term()) :: {:ok, map(), map()} | {:error, :invalid_connection | :invalid_root}
  def selected(body) do
    case nested_value(body, ["data", "repository", "issue"]) do
      %{} = root ->
        case Map.fetch(root, "subIssues") do
          {:ok, %{} = connection} -> {:ok, root, connection}
          _ -> {:error, :invalid_connection}
        end

      _ ->
        {:error, :invalid_root}
    end
  end

  @spec value(term()) :: {:ok, map()} | {:error, :invalid_connection}
  def value(%{} = connection), do: {:ok, connection}
  def value(_connection), do: {:error, :invalid_connection}

  @spec parse(term()) :: parsed()
  def parse(%{"nodes" => nodes, "totalCount" => total, "pageInfo" => page_info})
      when is_list(nodes) and is_integer(total) and total >= 0 and is_map(page_info) do
    with {:ok, has_next?} <- Map.fetch(page_info, "hasNextPage"),
         true <- is_boolean(has_next?),
         {:ok, end_cursor} <- Map.fetch(page_info, "endCursor"),
         true <- is_nil(end_cursor) or is_binary(end_cursor),
         true <- Enum.all?(nodes, &is_map/1) do
      {:ok, nodes, total, %{has_next?: has_next?, end_cursor: end_cursor}}
    else
      _ -> {:error, :invalid_connection}
    end
  end

  def parse(_connection), do: {:error, :invalid_connection}
  @spec total(term()) :: non_neg_integer()
  def total(%{"totalCount" => total}) when is_integer(total) and total >= 0, do: total
  def total(_connection), do: 0

  defp nested_value(value, []), do: value

  defp nested_value(%{} = value, [key | rest]) do
    case Map.fetch(value, key) do
      {:ok, nested} -> nested_value(nested, rest)
      :error -> nil
    end
  end

  defp nested_value(_value, _keys), do: nil
end
