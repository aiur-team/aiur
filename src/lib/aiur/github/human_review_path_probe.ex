defmodule Aiur.GitHub.HumanReviewPathProbe do
  # GitHub caps a comparison's file list at 300 entries (#4533). When only the
  # upstream side is capped, the PR's complete path set bounds the question:
  # compare each path's object id at both commits in one GraphQL read.
  @moduledoc false

  alias Aiur.GitHub.Transport

  @doc false
  @spec changed_paths(Enumerable.t(), String.t(), String.t(), map()) :: {:ok, MapSet.t()} | {:error, term()}
  def changed_paths(paths, from_sha, to_sha, context) do
    paths = Enum.to_list(paths)

    if paths == [] do
      {:ok, MapSet.new()}
    else
      fetch_changed(paths, from_sha, to_sha, context)
    end
  end

  defp fetch_changed(paths, from_sha, to_sha, context) do
    {:ok, {owner, name}} = Transport.parse_repo()
    indexed = Enum.with_index(paths)

    selections =
      Enum.map_join(indexed, "\n", fn {path, index} ->
        "f#{index}: object(expression: #{Jason.encode!(from_sha <> ":" <> path)}) { oid }\n" <>
          "t#{index}: object(expression: #{Jason.encode!(to_sha <> ":" <> path)}) { oid }"
      end)

    query = """
    query AiurHumanReviewPathBlobs($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        #{selections}
      }
    }
    """

    case Transport.github_graphql(context.request_fun, context.token, query, %{"owner" => owner, "name" => name}, caller: "human_review_base_ancestry") do
      {:ok, %{"data" => %{"repository" => objects}}} when is_map(objects) -> collect_changed(indexed, objects)
      {:ok, _body} -> {:error, :review_base_ancestry_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp collect_changed(indexed, objects) do
    Enum.reduce_while(indexed, {:ok, MapSet.new()}, fn {path, index}, {:ok, changed} ->
      with {:ok, from} <- object_id(objects, "f#{index}"),
           {:ok, to} <- object_id(objects, "t#{index}") do
        {:cont, {:ok, if(from == to, do: changed, else: MapSet.put(changed, path))}}
      else
        :error -> {:halt, {:error, :review_base_ancestry_unavailable}}
      end
    end)
  end

  # A missing path resolves to null; any other shape is not evidence.
  defp object_id(objects, key) do
    case Map.fetch(objects, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, %{"oid" => oid}} when is_binary(oid) and oid != "" -> {:ok, oid}
      _invalid -> :error
    end
  end
end
