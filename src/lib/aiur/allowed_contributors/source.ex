defmodule Aiur.AllowedContributors.Source do
  @moduledoc """
  Reads `.github/ALLOWED-CONTRIBUTORS` from the repository's **default branch**,
  pinned to the commit that last touched it.

  Four REST reads, never GraphQL:

    1. `GET /repos/{o}/{r}` — the repository's own `default_branch`. Never
       `tracker.base_branch`, never a configured ref: an integration branch an
       agent can push to is not where trust is decided.
    2. `GET /repos/{o}/{r}/branches/{default_branch}` — the branch's head
       commit SHA. From here on only that 40-hex SHA is used as a ref: a bare
       branch *name* passed as `ref`/`sha` is resolved by git rules, and a tag
       or other ref with the same name as the default branch could shadow it
       and serve an attacker-edited allow-list.
    3. `GET /repos/{o}/{r}/commits?sha=<head sha>&path=<file>&per_page=1` —
       the newest commit (reachable from that head) that touched the file.
       That SHA is what audit records and change alerts name.
    4. `GET /repos/{o}/{r}/contents/<file>?ref=<head sha>` — the file exactly
       as it is at the head of the default branch.

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
         {:ok, head} <- branch_head(get, base, branch),
         {:ok, sha} <- touching_commit(get, base, head) do
      contents_at(get, base, head, sha)
    end
  end

  defp default_branch(get, base) do
    case get.(base) do
      {:ok, %{status: 200, body: %{"default_branch" => branch}}} when is_binary(branch) and branch != "" -> {:ok, branch}
      other -> failure(other, :default_branch)
    end
  end

  # `/branches/{name}` names a branch, never a tag, so its answer is the
  # default branch's head. Branch names may contain `/`, which this endpoint
  # accepts unescaped; every other reserved character is escaped.
  defp branch_head(get, base, branch) do
    case get.("#{base}/branches/#{URI.encode(branch, &(&1 == ?/ or URI.char_unreserved?(&1)))}") do
      {:ok, %{status: 200, body: %{"commit" => %{"sha" => sha}}}} when is_binary(sha) -> validate_sha(sha, :branch)
      other -> failure(other, :branch)
    end
  end

  defp touching_commit(get, base, head) do
    case get.("#{base}/commits?sha=#{head}&path=#{URI.encode_www_form(@path)}&per_page=1") do
      {:ok, %{status: 200, body: []}} -> {:ok, :absent}
      {:ok, %{status: 200, body: [%{"sha" => sha} | _]}} when is_binary(sha) -> validate_sha(sha, :commits)
      other -> failure(other, :commits)
    end
  end

  defp validate_sha(sha, stage) do
    if Regex.match?(@sha, sha), do: {:ok, sha}, else: {:error, {:allowed_contributors, stage, :malformed_sha}}
  end

  defp contents_at(_get, _base, _head, :absent), do: {:ok, :absent}

  defp contents_at(get, base, head, sha) do
    case get.("#{base}/contents/#{@path}?ref=#{head}") do
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
