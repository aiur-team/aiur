defmodule Aiur.AllowedContributors.SourceTest do
  use ExUnit.Case, async: true

  alias Aiur.AllowedContributors.Source

  # `@sha` is the commit that last touched the file; `@head` is the default
  # branch's head. The file is read at the head, and the touching commit names
  # the version in audits.
  @sha String.duplicate("a", 40)
  @head String.duplicate("b", 40)

  # A fake GitHub that only knows the default-branch state. Any other read
  # (a PR head, a fork, a same-named tag, a branch name used as a ref) gets an
  # attacker's allow-list, so a test can prove it was never asked for.
  defp github(opts \\ []) do
    test = self()
    body = Keyword.get(opts, :body, "user 42\n")
    commits = Keyword.get(opts, :commits, [%{"sha" => @sha}])
    contents = Keyword.get(opts, :contents, {:ok, %{status: 200, body: file(body)}})

    fn %{url: url} ->
      send(test, {:get, url})

      cond do
        String.ends_with?(url, "/repos/acme/app") -> {:ok, %{status: 200, body: %{"default_branch" => "trunk"}}}
        String.ends_with?(url, "/branches/trunk") -> {:ok, %{status: 200, body: %{"commit" => %{"sha" => @head}}}}
        url =~ "/commits?sha=#{@head}&" -> {:ok, %{status: 200, body: commits}}
        url =~ "/contents/.github/ALLOWED-CONTRIBUTORS?ref=#{@head}" -> contents
        true -> {:ok, %{status: 200, body: file("user 666\n")}}
      end
    end
  end

  defp file(body), do: %{"type" => "file", "encoding" => "base64", "content" => Base.encode64(body)}
  defp fetch(request_fun), do: Source.fetch("acme", "app", request_fun: request_fun, token: "t")

  test "reads the file at the default branch's head SHA and audits the commit that touched it" do
    assert {:ok, %{sha: @sha, allowlist: %{users: users}}} = fetch(github())
    assert Map.has_key?(users, 42)

    assert_received {:get, repo_url}
    assert repo_url =~ ~r{/repos/acme/app$}
    assert_received {:get, branch_url}
    assert branch_url =~ ~r{/branches/trunk$}
    assert_received {:get, commits_url}
    assert commits_url =~ "sha=#{@head}"
    assert commits_url =~ "path=.github%2FALLOWED-CONTRIBUTORS"
    assert_received {:get, contents_url}
    assert contents_url =~ "?ref=#{@head}"
  end

  # Adversarial (#2957 review): a tag named like the default branch is resolved
  # ahead of the branch by git ref rules when a bare name is used as `ref`.
  # The branch name must never be used as a ref; only the branch head SHA is.
  test "a same-named tag cannot shadow the default branch" do
    assert {:ok, %{allowlist: %{users: users}}} = fetch(github())
    refute Map.has_key?(users, 666)

    refs =
      for {:get, url} <- collect_gets([]), String.contains?(url, "ref=") or String.contains?(url, "sha="), do: url

    assert refs != []
    assert Enum.all?(refs, &(&1 =~ @head)), "a ref other than the head SHA was used: #{inspect(refs)}"
    refute Enum.any?(refs, &(&1 =~ "=trunk"))
  end

  test "a branch-head answer that is not a SHA fails closed" do
    request_fun = fn
      %{url: "https://api.github.com/repos/acme/app"} -> {:ok, %{status: 200, body: %{"default_branch" => "main"}}}
      %{url: url} -> if url =~ "/branches/", do: {:ok, %{status: 200, body: %{"commit" => %{"sha" => "main"}}}}, else: flunk(url)
    end

    assert {:error, {:allowed_contributors, :branch, :malformed_sha}} = fetch(request_fun)
  end

  defp collect_gets(acc) do
    receive do
      {:get, url} -> collect_gets([{:get, url} | acc])
    after
      0 -> Enum.reverse(acc)
    end
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
