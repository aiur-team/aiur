defmodule Aiur.GitHub.ReadCacheBridgeTest do
  @moduledoc """
  The daemon's half of the bridge contract (#2327): a webhook delivery retires
  the `ReadCache` reads it supersedes, so raising a class TTL does not trade
  points for wrongness.

  `AgentCacheBridgeTest` covers the agent-side store; this covers the daemon's
  own. Both ride the same `{:github_resource_changed, …}` stream and both act
  on the same narrow set of parent identities, because a comment delivery
  always deposits the issue or pull request it hangs off.
  """

  use Aiur.TestSupport

  alias Aiur.GitHub.{ReadCache, ReadCache.Policy, ResourceStore}

  setup do
    ReadCache.reset()
    on_exit(&ReadCache.reset/0)

    start_supervised!({Aiur.GitHub.ReadCacheBridge, name: :"read_cache_bridge_#{System.unique_integer([:positive])}"})

    :ok
  end

  test "a webhook delivery retires a read cached before it" do
    request = graphql("issue_relationships", safe_document(1670))
    assert {:ok, _first} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)
    assert ReadCache.snapshot().entries == 1

    # The delivery deposits the issue (and, for a comment delivery, the comment
    # it hangs off). The parent's change is the event that retires the reads.
    deliver(:issue, 1670)
    assert await_marker({:number, "owner", "repo", 1670})

    assert {:ok, %{body: "second"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "second"}} end)
  end

  test "a delivery retires a cached comment list for the delivered issue" do
    request = rest("https://api.github.com/repos/owner/repo/issues/1670/comments?per_page=100")
    assert {:cache, :comments, _ttl} = Policy.classify(request)

    assert {:ok, _first} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)

    deliver(:issue, 1670)
    assert await_marker({:number, "owner", "repo", 1670})

    assert {:ok, %{body: "second"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "second"}} end)
  end

  test "a delivery of one number leaves reads of another number standing" do
    mine = graphql("issue_relationships", safe_document(1670))
    other = graphql("issue_relationships", safe_document(2088))

    assert {:ok, _one} = ReadCache.through(mine, fn -> {:ok, %{status: 200, body: "first"}} end)
    assert {:ok, _two} = ReadCache.through(other, fn -> {:ok, %{status: 200, body: "first"}} end)

    deliver(:issue, 1670)
    assert await_marker({:number, "owner", "repo", 1670})

    assert {:ok, %{body: "second"}} = ReadCache.through(mine, fn -> {:ok, %{status: 200, body: "second"}} end)
    assert {:ok, %{body: "first"}} = ReadCache.through(other, fn -> flunk("an unrelated delivery must not retire this") end)
  end

  # A comment delivery carries the parent issue in the same call, so a bare
  # comment deposit retires nothing — the narrow set exists to avoid retiring
  # the repository's collections twice, and the parent deposit is what fires.
  test "a comment delivery retires through the parent it is deposited with" do
    request = rest("https://api.github.com/repos/owner/repo/issues/1670/comments?per_page=100")
    assert {:ok, _first} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)

    deliver(:issue_comment, 99_001)
    Process.sleep(120)
    refute marker?({:number, "owner", "repo", 1670})

    # The same delivery's issue deposit is what does the retiring.
    deliver(:issue, 1670)
    assert await_marker({:number, "owner", "repo", 1670})

    assert {:ok, %{body: "second"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "second"}} end)
  end

  # Mirrors `@invalidating_types` rather than reading it, so the list cannot
  # change without this table changing too. All four are written by the webhook
  # pipe, so a delivery of each retires the reads that named its number.
  test "every invalidating type's deposit retires the read cache" do
    for {type, number} <- [issue: 1670, pull_request: 1671, issue_labels: 1672, branch_pull_request: 1673] do
      request = graphql("issue_relationships", safe_document(number))
      assert {:ok, _one} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)

      deliver(type, number)
      assert await_marker({:number, "owner", "repo", number}), "a #{type} deposit must retire the reads of that number"

      assert {:ok, %{body: "second"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "second"}} end)
    end
  end

  defp deliver(type, id) do
    key = ResourceStore.key(type, "owner", "repo", id)
    body = if type == :issue_labels, do: [%{"name" => "agent:todo"}], else: %{"number" => id}
    :ok = ResourceStore.put_resource(key, body, source: :webhook, version: "v1")
  end

  defp marker?(identity) do
    case :ets.lookup(:aiur_github_read_cache_markers, identity) do
      [{^identity, _at}] -> true
      _other -> false
    end
  end

  defp await_marker(identity, attempts \\ 100) do
    cond do
      marker?(identity) -> true
      attempts <= 0 -> false
      true -> Process.sleep(10) && await_marker(identity, attempts - 1)
    end
  end

  defp graphql(caller, document, variables \\ %{"owner" => "owner", "repo" => "repo"}) do
    %{
      method: :post,
      url: "https://api.github.com/graphql",
      token: "t",
      body: %{"query" => document, "variables" => variables},
      caller: caller
    }
  end

  defp rest(url), do: %{method: :get, url: url, token: "t"}

  defp safe_document(number) do
    "query Q($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { t0: issueOrPullRequest(number: #{number}) { ... on Issue { title } } } }"
  end
end
