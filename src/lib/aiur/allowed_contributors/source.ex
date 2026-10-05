defmodule Aiur.AllowedContributors.Source do
  @moduledoc """
  Reads `.github/ALLOWED-CONTRIBUTORS` from the repository's **default branch**,
  pinned to the commit that last touched it.

  Three REST reads, never GraphQL:

    1. `GET /repos/{o}/{r}` — the repository's own `default_branch`. Never
       `tracker.base_branch`, never a configured ref: an integration branch an
       agent can push to is not where trust is decided.
    2. `GET /repos/{o}/{r}/commits?sha=<default_branch>&path=<file>&per_page=1`
       — the newest default-branch commit that touched the file. That SHA is
       what every audit record names.
    3. `GET /repos/{o}/{r}/contents/<file>?ref=<that sha>` — the file exactly
       as it was at that commit, so the body and the audited SHA cannot
       disagree.

  Nothing here ever reads a pull-request head, a fork, an issue, or a
  comment: a PR that edits the allow-list changes nothing until it is merged
  to the default branch, and the merge itself is surfaced to the operator by
  `Aiur.AllowedContributors` as a change alert.
  """

  alias Aiur.AllowedContributors.AllowList
  alias Aiur.GitHub.{Errors, Transport}

  @path ".github/ALLOWED-CONTRIBUTORS"
  @sha ~r/\A[0-9a-f]{40}\z/

  @type snapshot :: %{sha: String.t(), allowlist: AllowList.t() | {:invalid, term()}}

  @doc "The repository-relative path of the allow-list file."
  @spec path() :: String.t()
  def path, do: @path

  @doc """
  Fetches the allow-list. `{:ok, :absent}` when the default branch has no such
  file (the feature is off); `{:error, reason}` when it could not be read.
  A file that exists but does not parse is `{:ok, %{allowlist: {:invalid, _}}}`
  so the caller can alert on the exact commit while admitting nobody.
  """
  @spec fetch(String.t(), String.t(), keyword()) :: {:ok, snapshot() | :absent} | {:error, term()}
  def fetch(owner, repo, opts) do
    request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    token = Keyword.fetch!(opts, :token)
    base = "#{Transport.base_url()}/repos/#{owner}/#{repo}"
    get = fn url -> request_fun.(%{method: :get, url: url, token: token, caller: "allowed_contributors"}) end

    with {:ok, branch} <- default_branch(get, base),
         {:ok, sha} <- pinning_commit(get, base, branch) do
      contents_at(get, base, sha)
    end
  end

  defp default_branch(get, base) do
    case get.(base) do
      {:ok, %{status: 200, body: %{"default_branch" => branch}}} when is_binary(branch) and branch != "" -> {:ok, branch}
      other -> failure(other, :default_branch)
    end
  end

  defp pinning_commit(get, base, branch) do
    url = "#{base}/commits?sha=#{URI.encode_www_form(branch)}&path=#{URI.encode_www_form(@path)}&per_page=1"

    case get.(url) do
      {:ok, %{status: 200, body: []}} -> {:ok, :absent}
      {:ok, %{status: 200, body: [%{"sha" => sha} | _]}} when is_binary(sha) -> validate_sha(sha)
      other -> failure(other, :commits)
    end
  end

  defp validate_sha(sha) do
    if Regex.match?(@sha, sha), do: {:ok, sha}, else: {:error, {:allowed_contributors, :commits, :malformed_sha}}
  end

  defp contents_at(_get, _base, :absent), do: {:ok, :absent}

  defp contents_at(get, base, sha) do
    case get.("#{base}/contents/#{@path}?ref=#{sha}") do
      {:ok, %{status: 200, body: %{"type" => "file", "encoding" => "base64", "content" => content}}} when is_binary(content) ->
        decode(content, sha)

      # The file was deleted by the newest commit that touched it.
      {:ok, %{status: 404}} ->
        {:ok, :absent}

      other ->
        failure(other, :contents)
    end
  end

  defp decode(content, sha) do
    case content |> String.replace(~r/\s/, "") |> Base.decode64() do
      {:ok, body} -> {:ok, %{sha: sha, allowlist: parsed(body)}}
      :error -> {:error, {:allowed_contributors, :contents, :malformed_base64}}
    end
  end

  defp parsed(body) do
    case AllowList.parse(body) do
      {:ok, allowlist} -> allowlist
      {:error, reason} -> {:invalid, reason}
    end
  end

  defp failure({:ok, %{status: 200}}, stage), do: {:error, {:allowed_contributors, stage, :malformed_response}}
  defp failure({:ok, %{status: _} = response}, stage), do: {:error, {:allowed_contributors, stage, Errors.github_status_error(response)}}
  defp failure({:error, reason}, stage), do: {:error, {:allowed_contributors, stage, Errors.classify_error({:error, reason})}}
  defp failure(_other, stage), do: {:error, {:allowed_contributors, stage, :invalid_response}}
end
