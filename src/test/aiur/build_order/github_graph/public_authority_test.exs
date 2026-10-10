defmodule Aiur.BuildOrder.GitHubGraph.PublicAuthorityTest do
  use ExUnit.Case, async: false

  import Aiur.BuildOrder.GitHubGraphFixtures

  alias Aiur.BuildOrder.GitHubGraph, as: ProductionGraph
  alias Aiur.BuildOrder.GitHubGraph.TestAdapter, as: GitHubGraph

  describe "public repository authority" do
    setup do
      previous_workflow_file_path = Application.get_env(:aiur, :workflow_file_path)
      fixture = Path.expand("../../../fixtures/test.yaml", __DIR__)

      Application.put_env(:aiur, :workflow_file_path, fixture)
      Aiur.WorkflowStore.force_reload()

      on_exit(fn ->
        case previous_workflow_file_path do
          nil -> Application.delete_env(:aiur, :workflow_file_path)
          path -> Application.put_env(:aiur, :workflow_file_path, path)
        end

        if Process.whereis(Aiur.WorkflowStore) do
          try do
            Aiur.WorkflowStore.force_reload()
          catch
            :exit, _reason -> :ok
          end
        end
      end)

      :ok
    end

    test "the Client facade retains graph contracts and body-free queries" do
      configured_repository = {"test-org", "test-repo"}
      root = root(1, "test-org", "test-repo")

      request_fun = fn %{body: %{"query" => query}} ->
        refute query =~ "body"
        assert query =~ "rateLimit { limit cost remaining resetAt }"
        selected_response(root, [], 0)
      end

      assert {:ok, %{candidate: %{root: %{identity: selected_identity}}}} =
               ProductionGraph.fetch_selected_root(identity(root, configured_repository), public_opts(request_fun))

      assert selected_identity == identity(root, configured_repository)

      catalog_request_fun = fn %{body: %{"query" => query}} ->
        refute query =~ "body"
        assert query =~ "subIssues(first: 100)"

        # Lifecycle plus the identity scalars the rare reconciliation needs to
        # deposit `:sub_issue` edges and member bodies (#2313). No nested
        # `labels` connection under `subIssues` — that is what took the
        # measured page cost from 1 point to 26 (#1766).
        assert String.replace(query, ~r/\s+/, " ") =~
                 "subIssues(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { id databaseId number title url createdAt updatedAt repository { name owner { login } } parent { id databaseId number url repository { name owner { login } } } state stateReason } }"

        catalog_response([], 0)
      end

      assert {:ok, %{candidate: %{entries: []}}} =
               ProductionGraph.fetch_catalog(public_opts(catalog_request_fun))
    end

    test "public graph reads derive their authority from validated configuration" do
      foreign_request = fn _request -> flunk("foreign authority must not reach GitHub") end

      assert {:error, %{error: :invalid_planning_authority, calls: 0, pages: 0}} =
               ProductionGraph.fetch_catalog(repository: {"foreign-owner", "foreign-repo"}, request_fun: foreign_request)

      for invalid_bound <- [[root_limit: 1], [page_budget: 1], [call_budget: 1]] do
        assert {:error, %{error: :invalid_planning_authority, calls: 0, pages: 0}} =
                 ProductionGraph.fetch_catalog(Keyword.put(invalid_bound, :request_fun, foreign_request))
      end

      root = root(1, "test-org", "test-repo")

      configured_request = fn %{body: %{"variables" => variables}} ->
        assert variables["owner"] == "test-org"
        assert variables["repo"] == "test-repo"
        catalog_response([root], 1)
      end

      assert {:ok, %{candidate: %{entries: [_entry]}}} =
               ProductionGraph.fetch_catalog(
                 repository: {"TEST-ORG", "TEST-REPO"},
                 root_limit: 100,
                 page_budget: 4,
                 call_budget: 4,
                 request_fun: configured_request
               )
    end

    # The opt-in labelled read must work through the PRODUCTION entry point, not
    # only the test adapter — the adapter carries its own copy of the wiring, so
    # an adapter-only test would still pass if `fetch_catalog/1` stopped honoring
    # the option and the catalog silently fell back to the cheap query forever.
    test "the production catalog read buys per-member labels only when asked" do
      members = [
        labelled_catalog_member(2, ["phase:1", "build-lane:runtime"]),
        labelled_catalog_member(3, ["phase:2", "build-lane:runtime"])
      ]

      root = Map.put(root(1, "test-org", "test-repo"), "subIssues", connection(members, 2, []))

      labelled_request = fn %{body: %{"query" => query, "variables" => variables}} ->
        assert catalog_sub_issues_selection(query) =~ "labels(first: 100)"

        # The labelled variant caps its own page size so its node estimate stays
        # inside GitHub's per-request ceiling (roots x 100 members x 100 labels).
        assert variables["pageSize"] <= 25

        catalog_response([root], 1)
      end

      assert {:ok, %{candidate: %{entries: [entry]}}} =
               ProductionGraph.fetch_catalog(
                 repository: {"test-org", "test-repo"},
                 root_limit: 100,
                 page_budget: 4,
                 call_budget: 4,
                 member_labels: true,
                 request_fun: labelled_request
               )

      assert entry.epic_count == 1
      assert entry.phase_count == 2

      # The cheap query returns members without labels, so the fixture must not
      # hand the normalizer labels the real response would never carry.
      cheap_root = Map.put(root(1, "test-org", "test-repo"), "subIssues", connection([catalog_member(2), catalog_member(3)], 2, []))

      cheap_request = fn %{body: %{"query" => query}} ->
        refute catalog_sub_issues_selection(query) =~ "labels"
        catalog_response([cheap_root], 1)
      end

      assert {:ok, %{candidate: %{entries: [cheap_entry]}}} =
               ProductionGraph.fetch_catalog(
                 repository: {"test-org", "test-repo"},
                 root_limit: 100,
                 page_budget: 4,
                 call_budget: 4,
                 request_fun: cheap_request
               )

      assert is_nil(cheap_entry.epic_count)
      assert is_nil(cheap_entry.phase_count)
    end

    # Node-limit guard for the labelled variant. `planning_page_budget: 1` makes
    # the budget-derived page size 100, which for the labelled query is roughly
    # 1.02M nodes — over GitHub's 500,000 per-request ceiling, which rejects the
    # whole read and would take the catalog down with it.
    test "caps the labelled catalog page size regardless of the paging budget" do
      for {page_budget, call_budget} <- [{1, 1}, {2, 2}, {4, 4}] do
        labelled = fn %{body: %{"variables" => variables}} ->
          assert variables["pageSize"] <= 25
          catalog_response([], 0)
        end

        assert {:ok, _result} =
                 GitHubGraph.fetch_catalog(
                   base_opts(labelled,
                     member_labels: true,
                     root_limit: 100,
                     page_budget: page_budget,
                     call_budget: call_budget
                   )
                 )
      end
    end
  end
end
