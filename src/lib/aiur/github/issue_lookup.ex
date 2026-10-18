defmodule Aiur.GitHub.IssueLookup do
  @moduledoc false
  alias Aiur.GitHub.{Errors, Transport}

  @spec find(String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def find(marker, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(), {:ok, token} <- Transport.require_token(opts) do
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues?state=all&sort=created&direction=desc&per_page=100"
      url = if opts[:since], do: url <> "&since=" <> URI.encode_www_form(opts[:since]), else: url
      pages(url, marker, token, Keyword.get(opts, :request_fun, &Transport.default_request_fun/1), 10)
    end
  end

  defp pages(nil, _marker, _token, _request, _remaining), do: {:ok, nil}
  defp pages(_url, _marker, _token, _request, 0), do: {:error, :incomplete_issue_lookup}

  defp pages(url, marker, token, request, remaining) do
    case request.(%{method: :get, url: url, token: token, caller: "experiment_analysis_reconcile"}) do
      {:ok, %{status: 200, body: rows} = response} when is_list(rows) ->
        resolve(rows, marker, token, request, remaining, Transport.parse_next_page_url(Map.get(response, :headers, [])))

      {:ok, response} ->
        {:error, Errors.github_status_error(response)}

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve(rows, marker, token, request, remaining, next) do
    matches = Enum.filter(rows, &(not Map.has_key?(&1, "pull_request") and is_binary(&1["body"]) and String.contains?(&1["body"], marker)))

    case matches do
      [%{"number" => number, "html_url" => url}] when is_integer(number) and number > 0 and is_binary(url) -> {:ok, %{"number" => number, "url" => url}}
      [] -> pages(next, marker, token, request, remaining - 1)
      _invalid -> {:error, :ambiguous_issue_lookup}
    end
  end
end
