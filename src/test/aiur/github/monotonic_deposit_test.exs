defmodule Aiur.GitHub.MonotonicDepositTest do
  use Aiur.TestSupport

  alias Aiur.Events.GithubCommentsPoller
  alias Aiur.GitHub.{ResourceFetch, ResourceStore, WriteThrough}

  @older "2026-10-07T10:00:00Z"
  @newer "2026-10-07T11:00:00Z"

  setup do
    ResourceStore.reset()
    on_exit(fn -> ResourceStore.reset() end)
    :ok
  end

  test "older deposit after newer is superseded without changing any entry metadata" do
    key = key()

    assert :ok =
             ResourceStore.deposit_unless_older(key, body(@newer),
               version: @newer,
               etag: "new",
               source: :webhook
             )

    assert {:ok, before} = ResourceStore.fetch(key)
    assert :ok = ResourceStore.subscribe(:issue)

    assert {:ok, :superseded} =
             ResourceStore.deposit_unless_older(key, body(@older),
               version: @older,
               etag: "old",
               processed: true
             )

    assert ResourceStore.fetch(key) == {:ok, before}
    refute ResourceStore.processed?(key, @older)
    refute_received {:github_resource_changed, %{key: ^key}}
  end

  test "equal markers write a changed body" do
    assert :ok = ResourceStore.deposit_unless_older(key(), body(@newer), version: @newer)
    changed = Map.put(body(@newer), "state", "closed")
    assert :ok = ResourceStore.deposit_unless_older(key(), changed, version: @newer)
    assert {:ok, %{data: ^changed, version: @newer}} = ResourceStore.fetch(key())
  end

  test "missing incoming or held markers permit writes" do
    assert :ok = ResourceStore.deposit_unless_older(key(), body(@newer), version: @newer)
    assert :ok = ResourceStore.deposit_unless_older(key(), %{"state" => "closed"})
    assert {:ok, %{data: %{"state" => "closed"}, version: nil}} = ResourceStore.fetch(key())
    assert :ok = ResourceStore.deposit_unless_older(key(), body(@older), version: @older)
    assert {:ok, %{data: %{"updated_at" => @older}, version: @older}} = ResourceStore.fetch(key())
  end

  test "nil keys are errors for both deposit entry points" do
    assert {:error, :invalid_key} = ResourceStore.put_resource(nil, body(@newer))
    assert {:error, :invalid_key} = ResourceStore.deposit_unless_older(nil, body(@newer))
  end

  test "a stale fetch reports superseded and returns the newer body and metadata" do
    newer = body(@newer)

    fetcher = fn _ ->
      assert :ok =
               ResourceStore.deposit_unless_older(key(), newer,
                 version: @newer,
                 etag: "new",
                 source: :webhook
               )

      {:ok, body(@older), "old"}
    end

    assert {:ok, ^newer, %{outcome: :superseded, spent?: true, version: @newer, etag: "new", fetched_at_ms: at}} =
             ResourceFetch.need(key(), fetcher, freshness: :strict)

    assert {:ok, %{data: ^newer, version: @newer, etag: "new", fetched_at_ms: ^at}} =
             ResourceStore.fetch(key())
  end

  test "a stale mutation response cannot roll back a webhook or mark the stale version processed" do
    newer = body(@newer)
    ResourceStore.put_resource(key(), newer, version: @newer, source: :webhook)
    assert :ok = WriteThrough.issue(body(@older), repo: "owner/repo")
    assert {:ok, %{data: ^newer, version: @newer}} = ResourceStore.fetch(key())
    refute ResourceStore.processed?(key(), @older)
  end

  # Future regression guard: undated poll lists deliberately remain unconditional.
  test "undated comment poller deposits keep updating comment bodies" do
    key = ResourceStore.key(:issue_comments, "owner", "repo", 1)

    for body <- ["before", "after"] do
      comments = [
        %{
          "id" => 123,
          "body" => "## Agent Workpad\n#{body}",
          "updated_at" => @newer,
          "user" => %{"login" => "its-applekid"}
        }
      ]

      request = fn %{url: url} ->
        {:ok, %{status: 200, body: if(String.contains?(url, "/comments?"), do: comments, else: [])}}
      end

      assert {:ok, %{errors: []}} =
               GithubCommentsPoller.poll(["1"],
                 repo: "owner/repo",
                 token: "test-token",
                 request_fun: request
               )

      assert {:ok, %{data: ^comments}} = ResourceStore.fetch(key)
    end
  end

  defp key, do: ResourceStore.key(:issue, "owner", "repo", 1)
  defp body(version), do: %{"number" => 1, "updated_at" => version, "state" => "open"}
end
