defmodule Aiur.GitHub.ReadCache.WebhookRetirementTest do
  @moduledoc """
  The properties the daemon read cache is worth having only if it holds.

  Three of them are safety, and they are asserted first: a CI verdict is never
  served from cache, review state is never served from cache, and an
  unrecognised read is never served from cache. A cache that fails any of those
  is worse than no cache, because the fleet would act on a check that has since
  failed.

  The rest are effectiveness: a hit costs nothing, a write retires what it
  changed, and every one of those events is counted — the metric the agent-side
  cache shipped without, which is why nobody can say whether that one worked.
  """

  use ExUnit.Case, async: false

  alias Aiur.Events.GithubWebhook.Deposit
  alias Aiur.GitHub.ReadCache
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Webhooks.ModeTable

  @repo "aiur-team/aiur"

  # The cache is an application child, so it is already running. Each test starts
  # from an empty store rather than from its own process, which is also the
  # shape the daemon runs in.
  setup do
    await_read_cache()
    ReadCache.reset()
    # The TTL is mode-aware now, and these tests exercise the 30-second bucket
    # for `@repo`. Ensure it is in polling mode so a stray webhook-backed record
    # (from any test anywhere) cannot turn a 31-second ageing into a hit.
    ModeTable.delete(@repo)
    on_exit(&ReadCache.reset/0)
    :ok
  end

  # The cache is an application child, so a test that stops it hands the restart
  # to its supervisor rather than to ExUnit. Waiting for that restart is the
  # difference between a suite that is order-independent and one that fails on
  # whichever test happens to run next.
  defp await_read_cache(attempts \\ 100) do
    cond do
      # Availability rather than registration: the name is registered before
      # `init/1` builds the tables, so a `whereis` can return a pid that has no
      # store behind it yet.
      ReadCache.snapshot().available? -> :ok
      attempts > 0 -> Process.sleep(10) || await_read_cache(attempts - 1)
      true -> start_supervised!({ReadCache, sweep_interval_ms: 0})
    end
  end

  describe "webhook deliveries retire what they deposit" do
    setup do
      on_exit(&ResourceStore.reset/0)
      :ok
    end

    test "a delivered issue comment retires a cached GraphQL read of that issue" do
      request = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit("issue_comment", issue_comment_delivery(2073), @repo)

      assert {:ok, %{body: "second"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a delivered comment retires the numbered REST comments read" do
      # The `:comments` class is `/issues/{n}/comments`, and a comment added to
      # issue n changes exactly what that read answers. A delivery must retire
      # it the same way it retires the GraphQL read of the issue.
      comments = rest("https://api.github.com/repos/aiur-team/aiur/issues/2073/comments?per_page=100")
      assert {:ok, _response} = ReadCache.through(comments, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit("issue_comment", issue_comment_delivery(2073), @repo)

      assert {:ok, %{body: "second"}} = ReadCache.through(comments, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a delivery for one issue leaves a read of a different issue cached" do
      request = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit("issue_comment", issue_comment_delivery(2070), @repo)

      assert {:ok, %{body: "first"}} = ReadCache.through(request, fn -> flunk("an unrelated delivery must not retire this") end)
    end

    test "a delivered pull request change retires a read of that pull request" do
      request = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit("pull_request", %{"action" => "synchronize", "pull_request" => %{"number" => 2073, "head" => %{"ref" => "aiur/42-x", "sha" => "new"}}}, @repo)

      assert {:ok, %{body: "second"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "an issue creation retires the repository's enumerating reads too" do
      enumerating =
        graphql(
          "issue_relationships",
          safe_document(2073) <> "\n branch_0: pullRequests(headRefName: \"x\") { nodes { number } }"
        )

      assert {:ok, _response} = ReadCache.through(enumerating, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit("issues", %{"action" => "opened", "issue" => %{"number" => 9999, "labels" => []}}, @repo)

      assert {:ok, %{body: "second"}} = ReadCache.through(enumerating, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a labeled delivery retires a numbers-free enumerating read" do
      # The `build_order_catalog` document names no numbers, so its identity
      # set is only [:root, {:repo, ...}, {:collections, ...}] — the collections
      # marker is the one identity a delivery can write that retires it. A
      # `labeled` delivery changes what a `labels: ["build-order"]` enumeration
      # answers (set membership) without creating or destroying a resource,
      # which is exactly the action a conditional collections marker would have
      # skipped — and a delivery that skips it serves pre-delivery bytes for
      # the whole webhook TTL.
      catalog = graphql("build_order_catalog", catalog_document())
      assert {:ok, _response} = ReadCache.through(catalog, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit(
        "issues",
        %{"action" => "labeled", "issue" => %{"number" => 2073, "labels" => [%{"name" => "build-order"}]}},
        @repo
      )

      assert {:ok, %{body: "second"}} = ReadCache.through(catalog, fn -> {:ok, %{status: 200, body: "second"}} end)
    end
  end

  defp graphql(caller, document, variables \\ %{"owner" => "aiur-team", "repo" => "aiur"}) do
    %{method: :post, url: "https://api.github.com/graphql", token: "t", body: %{"query" => document, "variables" => variables}, caller: caller}
  end

  defp rest(url), do: %{method: :get, url: url, token: "t"}

  defp safe_document(number) do
    "query Q($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { t0: issueOrPullRequest(number: #{number}) { ... on Issue { title } } } }"
  end

  # The `build_order_catalog` shape: an enumerating read that names no numbers,
  # so its identity set is only [:root, {:repo, ...}, {:collections, ...}].
  defp catalog_document do
    "query B($owner: String!, $repo: String!, $pageSize: Int!, $cursor: String) { repository(owner: $owner, name: $repo) { issues(first: $pageSize, after: $cursor, labels: [\"build-order\"]) { pageInfo { hasNextPage endCursor } nodes { number title } } } }"
  end

  defp issue_comment_delivery(number) do
    %{
      "action" => "created",
      "issue" => %{"number" => number, "labels" => []},
      "comment" => %{
        "id" => 55_001,
        "body" => "please rework",
        "created_at" => "2026-06-24T12:00:00Z",
        "updated_at" => "2026-06-24T12:00:00Z",
        "user" => %{"login" => "its-everdred"}
      }
    }
  end
end
