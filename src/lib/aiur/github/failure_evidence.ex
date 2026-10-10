defmodule Aiur.GitHub.FailureEvidence do
  @moduledoc "GitHub evidence for CI failure digests; annotations use Checks, never Actions logs."
  alias Aiur.GitHub.{Comments, ResourceFetch, ResourceStore, Transport}

  @spec annotations(integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def annotations(id, opts) when is_integer(id) and id > 0 do
    with {:ok, context} <- context(opts) do
      list(context, "/check-runs/#{id}/annotations?per_page=100")
    end
  end

  @spec known_flakes(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def known_flakes(sha, opts) do
    with {:ok, context} <- context(opts),
         {:ok, body} <-
           Transport.fetch_json_map(context.request, context.token, context.url <> "/contents/.github/known-flaky-tests.txt?" <> URI.encode_query(%{"ref" => sha}), caller: "ci_failure_digest"),
         %{"encoding" => "base64", "content" => encoded} when is_binary(encoded) <- body,
         {:ok, text} <- Base.decode64(String.replace(encoded, ~r/\s/, "")) do
      {:ok, text |> String.split("\n") |> Enum.map(&String.trim_trailing/1) |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim_leading(&1), "#")))}
    else
      {:error, {:github, :http, %{status: 404}}} -> {:ok, []}
      {:error, _} = error -> error
      _ -> {:error, :invalid_known_flakes_file}
    end
  end

  @spec flake_issues(keyword()) :: {:ok, [map()]} | {:error, term()}
  def flake_issues(opts) do
    with {:ok, context} <- context(opts) do
      key = ResourceStore.key_for_repo(:flake_issues, context.repo, "open")
      fetcher = fn _ -> list(context, "/issues?state=open&labels=flake&per_page=100") end

      case ResourceFetch.need(key, fetcher, freshness: {:max_age_ms, 60_000}, reason: "CI flake classification") do
        {:ok, issues, _} -> {:ok, Enum.reject(issues, &Map.has_key?(&1, "pull_request"))}
        {:error, _} = error -> error
      end
    end
  end

  defp list(context, path) do
    Comments.fetch_repo_comment_stream(context.request, context.token, context.url <> path, [], caller: "ci_failure_digest")
  end

  defp context(opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      {:ok, %{repo: "#{owner}/#{repo}", url: "#{Transport.base_url()}/repos/#{owner}/#{repo}", token: token, request: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)}}
    end
  end
end
