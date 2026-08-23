defmodule Aiur.BuildOrder.GraphProjection.StoreCatalogTest do
  @moduledoc """
  The event-sourced catalog (acceptance #2325): roots and their membership are
  derived from `Aiur.GitHub.ResourceStore` content, so a sub-issue added outside
  Aiur changes the catalog with no fetch.
  """

  use Aiur.TestSupport

  alias Aiur.BuildOrder.{Catalog, RootSummary}
  alias Aiur.BuildOrder.GraphProjection.StoreCatalog
  alias Aiur.GitHub.ResourceStore

  @owner "owner"
  @repo "owner/repo"

  setup do
    ensure_resource_store!()
    ensure_pubsub!()
    ResourceStore.reset()
    :ok
  end

  test "builds a build-order root and derives its membership from sub-issues" do
    deposit_issue(10, "Root", ["build-order"], "open")
    deposit_issue(11, "Member one", [], "closed", "completed")
    deposit_issue(12, "Member two", [], "open")
    deposit_sub_issue(11, "IS_member_one", 10)
    deposit_sub_issue(12, "IS_member_two", 10)

    assert %Catalog{entries: [root]} = StoreCatalog.build(@repo)

    assert %RootSummary{} = root
    assert root.title == "Root"
    assert root.labels == ["build-order"]
    assert root.member_count == 2
    # One of two resolved members is completed.
    assert root.progress == 50
    assert root.progress_resolution == :resolved
    assert root.progress_resolved_count == 2
    # Members carry no build-lane/phase labels, so the unassigned/unphased
    # cohort counts as one distinct group — the same claim the GraphQL catalog
    # makes.
    assert root.epic_count == 1
    assert root.phase_count == 1
    assert root.member_state_digest != nil
  end

  test "a pull request is not a root even when it carries the label" do
    deposit_issue(10, "Root", ["build-order"], "open")
    deposit_issue(20, "Not a root", ["build-order"], "open", nil, pull_request?: true)

    assert Enum.map(StoreCatalog.build(@repo).entries, & &1.title) == ["Root"]
  end

  test "removing a sub-issue edge drops it from the root's membership" do
    deposit_issue(10, "Root", ["build-order"], "open")
    deposit_issue(11, "Member", [], "open")
    deposit_sub_issue(11, "IS_member", 10)

    assert Enum.at(StoreCatalog.build(@repo).entries, 0).member_count == 1

    ResourceStore.drop_data(ResourceStore.key_for_repo(:sub_issues, @repo, "IS_member"))

    assert Enum.at(StoreCatalog.build(@repo).entries, 0).member_count == 0
  end

  test "a member closed as not_planned does not count toward completion" do
    deposit_issue(10, "Root", ["build-order"], "open")
    deposit_issue(11, "Done", [], "closed", "completed")
    deposit_issue(12, "Skipped", [], "closed", "not_planned")
    deposit_sub_issue(11, "IS_done", 10)
    deposit_sub_issue(12, "IS_skipped", 10)

    root = Enum.at(StoreCatalog.build(@repo).entries, 0)
    assert root.progress == 50
    assert root.member_count == 2
  end

  test "a member whose issue body is missing contributes from the sub-issue edge" do
    deposit_issue(10, "Root", ["build-order"], "open")
    # No `:issue` body for member 11; only the edge carries its lifecycle.
    deposit_sub_issue(11, "IS_member", 10, state: "closed", state_reason: "completed")

    root = Enum.at(StoreCatalog.build(@repo).entries, 0)
    assert root.member_count == 1
    assert root.progress == 100
  end

  test "build answers an empty unavailable catalog for an unparseable repo" do
    assert %Catalog{entries: []} = StoreCatalog.build(nil)
    assert %Catalog{entries: []} = StoreCatalog.build("norepo")
  end

  # Finding #3 (cold start): a store-derived catalog with no roots must not claim
  # `:healthy`. Right after a restart the store holds almost nothing — an empty
  # derivation is not evidence that there are no roots, so it reports
  # `:unavailable` until the store demonstrably holds planning data.
  test "an empty store derives an unavailable catalog, never a healthy one" do
    assert %Catalog{entries: [], provider: %{state: :unavailable}} = StoreCatalog.build(@repo)
  end

  # -- fixtures ---------------------------------------------------------------

  defp deposit_issue(number, title, labels, state, state_reason \\ nil, opts \\ []) do
    body =
      %{
        "number" => number,
        "node_id" => "IS_#{number}",
        "title" => title,
        "state" => state,
        "html_url" => "https://github.com/owner/repo/issues/#{number}",
        "labels" => Enum.map(labels, &%{"name" => &1}),
        "created_at" => "2026-07-15T10:00:00Z",
        "updated_at" => "2026-07-15T10:00:00Z",
        "repository_url" => "https://api.github.com/repos/owner/repo"
      }
      |> maybe_put("state_reason", state_reason)
      |> maybe_put("pull_request", if(Keyword.get(opts, :pull_request?), do: %{"url" => "x"}, else: nil))

    ResourceStore.put_resource(ResourceStore.key(:issue, @owner, "repo", number), body,
      source: :webhook,
      version: "2026-07-15T10:00:00Z"
    )
  end

  defp deposit_sub_issue(number, node_id, parent_number, opts \\ []) do
    sub_issue =
      %{
        "node_id" => node_id,
        "number" => number,
        "state" => Keyword.get(opts, :state, "open")
      }
      |> maybe_put("state_reason", Keyword.get(opts, :state_reason))

    edge = Map.put(sub_issue, "parent", %{"node_id" => "IS_#{parent_number}", "number" => parent_number})

    ResourceStore.put_resource(ResourceStore.key(:sub_issues, @owner, "repo", node_id), edge,
      source: :webhook,
      version: "2026-07-15T10:00:00Z"
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ensure_resource_store! do
    if Process.whereis(ResourceStore) == nil do
      Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
    end

    :ok
  end

  defp ensure_pubsub! do
    unless Process.whereis(Aiur.PubSub) do
      {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end
end
