defmodule Aiur.PrMerge.Reviews do
  @moduledoc false
  alias Aiur.PrMerge.Client
  @decisive ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]

  @spec read(function(), String.t(), pos_integer(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def read(api, repo, number, head) do
    with {:ok, reviews} <- Client.pages(api, "repos/#{repo}/pulls/#{number}/reviews"),
         true <- Enum.all?(reviews, &valid?/1) do
      decisions =
        reviews
        |> Enum.filter(&(&1["state"] in @decisive))
        |> Enum.sort_by(&{timestamp(&1["submitted_at"]), &1["id"]})
        |> Enum.reduce(%{}, &Map.put(&2, &1["user"]["id"], &1))
        |> Map.values()

      {:ok,
       %{
         approved: Enum.any?(decisions, &(&1["state"] == "APPROVED" and &1["commit_id"] == head)),
         changes_requested: Enum.any?(decisions, &(&1["state"] == "CHANGES_REQUESTED"))
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:error, "invalid GitHub review observation"}
    end
  end

  defp valid?(%{"id" => id, "user" => %{"id" => user}, "state" => state} = review) when is_integer(id) and is_integer(user) do
    case state do
      state when state in @decisive -> is_binary(review["commit_id"]) and valid_timestamp?(review["submitted_at"])
      state when state in ["COMMENTED", "PENDING"] -> true
      _ -> false
    end
  end

  defp valid?(_review), do: false

  defp timestamp(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    DateTime.to_unix(datetime, :microsecond)
  end

  defp valid_timestamp?(value) when is_binary(value), do: match?({:ok, _, _}, DateTime.from_iso8601(value))
  defp valid_timestamp?(_value), do: false
end
