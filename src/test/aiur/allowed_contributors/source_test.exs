defmodule Aiur.AllowedContributors.SourceTest do
  use ExUnit.Case, async: true

  alias Aiur.AllowedContributors.Source

  @sha String.duplicate("a", 40)

  # A fake GitHub that only knows the default-branch state. Any other read
  # (a PR head, a fork, a different ref) is recorded so the test can prove it
  # was never asked for.
  defp github(opts \\ []) do
    test = self()
    body = Keyword.get(opts, :body, "user 42\n")
    commits = Keyword.get(opts, :commits, [%{"sha" => @sha}])
    contents = Keyword.get(opts, :contents, {:ok, %{status: 200, body: file(body)}})

    fn %{url: url} ->
      send(test, {:get, url})

      cond do
        String.ends_with?(url, "/repos/acme/app") -> {:ok, %{status: 200, body: %{"default_branch" => "trunk"}}}
        url =~ "/commits?" -> {:ok, %{status: 200, body: commits}}
        url =~ "/contents/.github/ALLOWED-CONTRIBUTORS?ref=#{@sha}" -> contents
        true -> {:ok, %{status: 200, body: file("user 666\n")}}
      end
    end
  end

  defp file(body), do: %{"type" => "file", "encoding" => "base64", "content" => Base.encode64(body)}
  defp fetch(request_fun), do: Source.fetch("acme", "app", request_fun: request_fun, token: "t")

  test "reads the file at the default-branch commit that last touched it" do
    assert {:ok, %{sha: @sha, allowlist: %{users: users}}} = fetch(github())
    assert MapSet.member?(users, 42)

    assert_received {:get, repo_url}
    assert repo_url =~ ~r{/repos/acme/app$}
    assert_received {:get, commits_url}
    assert commits_url =~ "sha=trunk"
    assert commits_url =~ "path=.github%2FALLOWED-CONTRIBUTORS"
    assert_received {:get, contents_url}
    assert contents_url =~ "?ref=#{@sha}"
  end

  test "an empty commit history or a deleted file means the feature is off" do
    assert {:ok, :absent} = fetch(github(commits: []))
    assert {:ok, :absent} = fetch(github(contents: {:ok, %{status: 404}}))
  end

  test "a malformed file is surfaced as invalid at its commit, never partially applied" do
    assert {:ok, %{sha: @sha, allowlist: {:invalid, {:line, 2, _}}}} = fetch(github(body: "user 42\nmallory\n"))
  end

  test "read failures are errors, not an empty allow-list" do
    assert {:error, {:allowed_contributors, :contents, _}} = fetch(github(contents: {:ok, %{status: 403}}))
    assert {:error, {:allowed_contributors, :contents, _}} = fetch(github(contents: {:error, :timeout}))
    assert {:error, {:allowed_contributors, :commits, :malformed_sha}} = fetch(github(commits: [%{"sha" => "HEAD"}]))
  end
end
