defmodule Aiur.GitHub.PullRequests.CommitCiStatus do
  @moduledoc false

  alias Aiur.GitHub.{Errors, ResourceFetch, ResourceStore, Transport}

  @spec fetch(String.t(), String.t(), String.t(), String.t(), function(), String.t()) ::
          {:ok, %{check_runs: [map()], commit_status: map()}} | {:error, term()}
  def fetch(owner, repo, sha, base_url, request_fun, token) do
    with {:ok, check_runs} <-
           fetch_check_runs(request_fun, token, base_url <> "/check-runs?filter=latest&per_page=100", owner, repo, sha),
         {:ok, commit_status} <- fetch_commit_status(request_fun, token, base_url <> "/status", owner, repo, sha) do
      {:ok, %{check_runs: check_runs, commit_status: commit_status}}
    end
  end

  defp fetch_check_runs(request_fun, token, url, owner, repo, sha, page \\ 1, acc \\ []) do
    key = ResourceStore.key(:commit_ci_check_runs, owner, repo, "#{sha}:#{page}")
    fetcher = fn fetch_opts -> fetch_check_runs_page(request_fun, token, url, fetch_opts) end

    with {:ok, %{"check_runs" => runs, "next" => next}, _meta} <-
           ResourceFetch.need(key, fetcher, freshness: ResourceFetch.decision(), reason: "commit CI check runs") do
      if is_binary(next),
        do: fetch_check_runs(request_fun, token, next, owner, repo, sha, page + 1, acc ++ runs),
        else: {:ok, acc ++ runs}
    end
  end

  defp fetch_check_runs_page(request_fun, token, url, fetch_opts) do
    request = conditional_request(url, token, "commit_ci_check_runs", fetch_opts)

    case request_fun.(request) do
      {:ok, %{status: 200, body: %{"check_runs" => runs}} = response} when is_list(runs) ->
        next = Transport.parse_next_page_url(Map.get(response, :headers, []))
        snapshot = %{"check_runs" => runs, "next" => next}
        {:ok, snapshot, Transport.header(Map.get(response, :headers, []), "etag")}

      {:ok, %{status: 200}} ->
        {:error, :invalid_ci_status_response}

      {:ok, %{status: 304} = response} ->
        {:not_modified, response_etag(response, fetch_opts)}

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp fetch_commit_status(request_fun, token, url, owner, repo, sha) do
    key = ResourceStore.key(:commit_ci_status, owner, repo, sha)
    fetcher = fn fetch_opts -> fetch_status_page(request_fun, token, url, fetch_opts) end

    with {:ok, body, _meta} <-
           ResourceFetch.need(key, fetcher, freshness: ResourceFetch.decision(), reason: "commit CI status"),
         true <- is_map(body) do
      {:ok, body}
    else
      false -> {:error, :invalid_ci_status_response}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_status_page(request_fun, token, url, fetch_opts) do
    request = conditional_request(url, token, "commit_ci_status", fetch_opts)

    case request_fun.(request) do
      {:ok, %{status: 200, body: body} = response} when is_map(body) ->
        {:ok, body, Transport.header(Map.get(response, :headers, []), "etag")}

      {:ok, %{status: 304} = response} ->
        {:not_modified, response_etag(response, fetch_opts)}

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp conditional_request(url, token, caller, fetch_opts) do
    request = %{method: :get, url: url, token: token, caller: caller}
    if is_binary(fetch_opts[:etag]), do: Map.put(request, :etag, fetch_opts[:etag]), else: request
  end

  defp response_etag(response, fetch_opts),
    do: Transport.header(Map.get(response, :headers, []), "etag") || fetch_opts[:etag]
end
