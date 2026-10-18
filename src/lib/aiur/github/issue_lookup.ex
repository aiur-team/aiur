defmodule Aiur.GitHub.IssueLookup do
  @moduledoc false
  alias Aiur.GitHub.{Errors, Transport}

  @spec find(String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def find(marker, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(), {:ok, token} <- Transport.require_token(opts) do
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues?state=all&sort=created&direction=desc&per_page=100"
      url = if opts[:since], do: url <> "&since=" <> URI.encode_www_form(opts[:since]), else: url
      cutoff = parse_timestamp(opts[:since])
      pages(url, marker, token, Keyword.get(opts, :request_fun, &Transport.default_request_fun/1), %{cutoff: cutoff, remaining: if(cutoff, do: :bounded_by_creation, else: 10), seen: %{}})
    end
  end

  defp pages(nil, _marker, _token, _request, _pagination), do: {:ok, nil}
  defp pages(_url, _marker, _token, _request, %{remaining: 0}), do: {:error, :incomplete_issue_lookup}

  defp pages(url, marker, token, request, pagination) do
    if Map.has_key?(pagination.seen, url) do
      {:error, :incomplete_issue_lookup}
    else
      fetch_page(url, marker, token, request, %{pagination | seen: Map.put(pagination.seen, url, true)})
    end
  end

  defp fetch_page(url, marker, token, request, pagination) do
    case request.(%{method: :get, url: url, token: token, caller: "experiment_analysis_reconcile"}) do
      {:ok, %{status: 200, body: rows} = response} when is_list(rows) ->
        {eligible, older} = Enum.split_while(rows, &(not before_cutoff?(&1, pagination.cutoff)))
        next = if older == [], do: Transport.parse_next_page_url(Map.get(response, :headers, []))
        resolve(eligible, marker, token, request, pagination, next)

      {:ok, response} ->
        {:error, Errors.github_status_error(response)}

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve(rows, marker, token, request, pagination, next) do
    matches = Enum.filter(rows, &(not Map.has_key?(&1, "pull_request") and is_binary(&1["body"]) and String.contains?(&1["body"], marker)))

    case matches do
      [%{"number" => number, "html_url" => url}] when is_integer(number) and number > 0 and is_binary(url) -> {:ok, %{"number" => number, "url" => url}}
      [] -> pages(next, marker, token, request, %{pagination | remaining: advance(pagination.remaining)})
      _invalid -> {:error, :ambiguous_issue_lookup}
    end
  end

  # GitHub's since parameter filters updated_at, not created_at. The descending
  # creation order supplies the actual boundary, even when old issues were updated.
  defp before_cutoff?(_row, nil), do: false

  defp before_cutoff?(row, cutoff) do
    case parse_timestamp(row["created_at"]) do
      nil -> false
      created -> DateTime.compare(created, cutoff) == :lt
    end
  end

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      _invalid -> nil
    end
  end

  defp parse_timestamp(_value), do: nil
  defp advance(:bounded_by_creation), do: :bounded_by_creation
  defp advance(remaining), do: remaining - 1
end
