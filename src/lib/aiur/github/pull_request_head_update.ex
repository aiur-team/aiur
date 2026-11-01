defmodule Aiur.GitHub.PullRequestHeadUpdate do
  @moduledoc "Preserves head-specific timestamps from verified pull-request deliveries."

  @field "head_updated_at"

  @spec capture(map(), String.t() | nil) :: map()
  def capture(pr, action) do
    pr = Map.delete(pr, @field)

    if action in ["opened", "synchronize"] and valid_head?(pr) and valid_timestamp?(pr["updated_at"]),
      do: Map.put(pr, @field, pr["updated_at"]),
      else: pr
  end

  @spec inherit(term(), map()) :: map()
  def inherit(held, body) when is_map(held) do
    cond do
      valid_head?(body) and valid_timestamp?(body[@field]) -> body
      same_head?(held, body) and valid_timestamp?(held[@field]) -> Map.put(body, @field, held[@field])
      true -> Map.delete(body, @field)
    end
  end

  def inherit(_held, body), do: body

  @doc "Whether a held body retains head-specific delivery evidence after a partial poll write."
  @spec proven?(map()) :: boolean()
  def proven?(body), do: valid_head?(body) and valid_timestamp?(body[@field])

  defp same_head?(held, body), do: valid_head?(body) and held["number"] == body["number"] and get_in(held, ["head", "sha"]) == get_in(body, ["head", "sha"])
  defp valid_head?(body), do: is_binary(get_in(body, ["head", "sha"])) and get_in(body, ["head", "sha"]) != ""

  defp valid_timestamp?(value) when is_binary(value) do
    match?({:ok, %DateTime{}, _offset}, DateTime.from_iso8601(value))
  end

  defp valid_timestamp?(_value), do: false
end
