defmodule Aiur.BuildOrder.CatalogStoreTest do
  @moduledoc """
  The event-sourced catalog: `Aiur.BuildOrder.CatalogStore` builds the catalog
  from `Aiur.GitHub.ResourceStore` alone, with zero GitHub reads (#2313).

  The store is seeded exactly the way webhook deliveries and the rare
  reconciliation populate it — `:issue`, `:issue_labels` and `:sub_issue`
  entries — and the catalog is derived from that state. The metric claims
  (progress, member count, lane/phase counts) must match what the GraphQL
  normalizer would report for the same member facts.
  """

  use Aiur.TestSupport

  alias Aiur.BuildOrder.{Catalog, CatalogStore, ProviderResult}
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Workflow

  @repo "owner/repo"
  @repository {"owner", "repo"}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: @repo,
      tracker_label_prefix: "aiur",
      tracker_bot_account: "its-applekid"
    )

    ResourceStore.reset()

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      if is_nil(Process.whereis(ResourceStore)) do
        Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
      end

      ResourceStore.reset()
    end)

    :ok
  end

  test "a labelled root with members projects a catalog entry with progress" do
    seed_issue(100, "Build Order 1", "open", %{
      "build-order" => "",
      "phase:1" => "",
      "phase:2" => ""
    })

    seed_issue(101, "Member A", "closed", %{"state_reason" => "completed", "phase:1" => ""})
    seed_issue(102, "Member B", "open", %{"phase:2" => ""})
    seed_edge(:sub_issue, "100:101", %{"parent_issue_number" => 100, "sub_issue_number" => 101})
    seed_edge(:sub_issue, "100:102", %{"parent_issue_number" => 100, "sub_issue_number" => 102})

    assert {:ok, %ProviderResult{status: :complete, candidate: %Catalog{entries: [root]}}} =
             CatalogStore.fetch(repository: @repository)

    assert root.title == "Build Order 1"
    assert root.member_count == 2
    assert root.progress == 50
    assert root.progress_resolution == :resolved
    # Members carry one distinct lane label group and one distinct phase group.
    assert root.phase_count == 2
    assert is_integer(root.member_state_digest)
  end

  test "a root with no member bodies reports unresolved progress but its edge count" do
    seed_issue(200, "Build Order 2", "open", %{"build-order" => ""})
    seed_edge(:sub_issue, "200:201", %{"parent_issue_number" => 200, "sub_issue_number" => 201})

    assert {:ok, %ProviderResult{candidate: %Catalog{entries: [root]}}} = CatalogStore.fetch(repository: @repository)

    assert root.member_count == 1
    assert root.progress == nil
    assert root.progress_resolution == :unresolved
  end

  test "a tombstoned edge no longer counts a member" do
    seed_issue(300, "Build Order 3", "open", %{"build-order" => ""})
    seed_issue(301, "Member", "open", %{})
    seed_edge(:sub_issue, "300:301", %{"parent_issue_number" => 300, "sub_issue_number" => 301, "present" => false})

    assert {:ok, %ProviderResult{candidate: %Catalog{entries: [root]}}} = CatalogStore.fetch(repository: @repository)

    assert root.member_count == 0
  end

  test "an unlabelled issue is not a root" do
    seed_issue(400, "Not a Build Order", "open", %{"phase:1" => ""})

    assert {:ok, %ProviderResult{candidate: %Catalog{entries: []}}} = CatalogStore.fetch(repository: @repository)
  end

  test "member_numbers/1 maps parents to their present members" do
    seed_edge(:sub_issue, "500:501", %{"parent_issue_number" => 500, "sub_issue_number" => 501})
    seed_edge(:sub_issue, "500:502", %{"parent_issue_number" => 500, "sub_issue_number" => 502})
    seed_edge(:sub_issue, "500:503", %{"parent_issue_number" => 500, "sub_issue_number" => 503, "present" => false})

    assert CatalogStore.member_numbers(@repository) == %{500 => [501, 502]}
  end

  # -- seeding helpers ------------------------------------------------------

  defp seed_issue(number, title, state, label_map) do
    labels = for {name, _} <- label_map, do: %{"name" => name}

    issue = %{
      "id" => number,
      "node_id" => "DI_#{number}",
      "number" => number,
      "title" => title,
      "html_url" => "https://github.com/owner/repo/issues/#{number}",
      "url" => "https://github.com/owner/repo/issues/#{number}",
      "repository_url" => "https://api.github.com/repos/owner/repo",
      "state" => state,
      "state_reason" => Map.get(label_map, "state_reason"),
      "created_at" => "2026-06-24T10:00:00Z",
      "updated_at" => "2026-06-24T11:00:00Z",
      "labels" => labels
    }

    ResourceStore.put_resource(ResourceStore.key_for_repo(:issue, @repo, number), issue,
      source: :webhook,
      version: issue["updated_at"]
    )

    ResourceStore.put_resource(ResourceStore.key_for_repo(:issue_labels, @repo, number), labels,
      source: :webhook,
      version: issue["updated_at"]
    )

    :ok
  end

  defp seed_edge(type, id, edge) do
    ResourceStore.put_resource(ResourceStore.key_for_repo(type, @repo, id), Map.put_new(edge, "present", true),
      source: :webhook,
      version: "2026-06-24T12:00:00Z"
    )

    :ok
  end
end
