defmodule Aiur.GitHub.Transport.RequestOptions do
  @moduledoc false

  alias Aiur.GitHub.Transport.OffProcess

  @default_request_timeout_ms 30_000

  def headers(token, req) do
    case Map.get(req, :etag) do
      nil -> github_headers(token, req)
      etag -> [{"If-None-Match", etag} | github_headers(token, req)]
    end
  end

  def options(headers, req) do
    options = Application.get_env(:aiur, :github_transport_test_options, [])
    options = if is_list(options) and Keyword.keyword?(options), do: options, else: []
    timeout_ms = Map.get(req, :timeout_ms, @default_request_timeout_ms)

    options
    |> Keyword.merge(headers: headers, connect_options: [timeout: timeout_ms], receive_timeout: timeout_ms, retry: false)
    |> OffProcess.maybe_bound_response(req)
  end

  defp github_headers(token, req) do
    version =
      case req do
        %{api_version: version} when is_binary(version) -> version
        _ -> "2022-11-28"
      end

    base = [{"Accept", "application/vnd.github+json"}, {"X-GitHub-Api-Version", version}]
    if is_binary(token) and token != "", do: [{"Authorization", "Bearer #{token}"} | base], else: base
  end
end
