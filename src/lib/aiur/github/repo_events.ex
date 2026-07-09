defmodule Aiur.GitHub.RepoEvents do
  @moduledoc """
  GitHub repo-events firehose domain.
  """

  alias Aiur.GitHub.{Errors, Transport}

  @doc """
  Fetches `/repos/{owner}/{repo}/events` (the GitHub firehose for the
  current repo). Honors `If-None-Match` via the optional `etag:` option,
  and the `X-Poll-Interval` response header for next-poll scheduling.

  Returns:

    * `{:ok, {:not_modified, etag, poll_interval}}` on 304
    * `{:ok, {:events, list, etag, poll_interval}}` on 200
    * `{:error, reason}` on transport or 4xx/5xx errors

  `poll_interval` is in seconds, defaulting to 60 when GitHub omits the
  header.

  Options:

    * `:page` — GitHub events page to fetch, defaulting to 1
    * `:per_page` — events per page, defaulting to 30
  """
  @spec fetch_repo_events(keyword()) ::
          {:ok,
           {:events, [map()], String.t() | nil, pos_integer()}
           | {:not_modified, String.t() | nil, pos_integer()}}
          | {:error, term()}
  def fetch_repo_events(opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      etag = Keyword.get(opts, :etag)
      page = Keyword.get(opts, :page, 1)
      per_page = Keyword.get(opts, :per_page, 30)

      query = URI.encode_query(%{"page" => page, "per_page" => per_page})
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/events?#{query}"

      case request_fun.(%{
             method: :get,
             url: url,
             token: token,
             etag: etag
           }) do
        {:ok, %{status: 304, headers: headers}} ->
          {:ok, {:not_modified, Transport.header(headers, "etag") || etag, Transport.poll_interval(headers)}}

        {:ok, %{status: 200, headers: headers, body: body}} when is_list(body) ->
          # Mirror the 304 path: preserve the prior etag if GitHub
          # omits the response header (rare but observed behind some
          # caching proxies). Dropping it would force a non-conditional
          # GET on the next poll, re-translating the same page of events.
          {:ok, {:events, body, Transport.header(headers, "etag") || etag, Transport.poll_interval(headers)}}

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end
end
