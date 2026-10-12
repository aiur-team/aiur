defmodule Aiur.GitHub.OpenIssueListingTest do
  use Aiur.TestSupport
  alias Aiur.GitHub.{Issues, OpenIssueListing, OpenIssueSnapshot}

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    :ok
  end

  describe "complete open listing publication" do
    test "complete paginated polls record all labels with no extra requests" do
      OpenIssueListing.subscribe("owner/repo")
      OpenIssueSnapshot.reset()
      on_exit(fn -> OpenIssueSnapshot.reset() end)
      Phoenix.PubSub.subscribe(Aiur.PubSub, "tracker:open_issues")
      previous_scope = System.get_env("AIUR_DEV_TEST_TICKET_IDS")
      on_exit(fn -> restore_env("AIUR_DEV_TEST_TICKET_IDS", previous_scope) end)
      System.put_env("AIUR_DEV_TEST_TICKET_IDS", "7")
      parent = self()
      base_url = "https://api.github.com/repos/owner/repo/issues?state=open&per_page=100"
      second_url = base_url <> "&page=2"

      issue = fn number ->
        %{"number" => number, "title" => "Open issue", "labels" => [%{"name" => "AGENT:QUEUED"}, %{"name" => "sym:done"}], "updated_at" => "2026-10-06T00:00:00Z"}
      end

      request_fun = fn request ->
        send(parent, {:list_request, request.url})

        if request.url == base_url do
          send(parent, {:first_page_at, DateTime.utc_now()})
        end

        cond do
          Map.has_key?(request, :etag) -> {:ok, %{status: 304, headers: []}}
          request.url == base_url -> {:ok, %{status: 200, headers: [{"etag", "page-one"}, {"link", "<#{second_url}>; rel=\"next\""}], body: [issue.(7)]}}
          request.url == second_url -> {:ok, %{status: 200, headers: [{"etag", "page-two"}], body: [issue.(8)]}}
          true -> flunk("unexpected request: #{request.url}")
        end
      end

      expected = Map.new(["7", "8"], &{&1, %{labels: ["agent:queued", "sym:done"], updated_at: ~U[2026-10-06 00:00:00Z]}})
      before_request = DateTime.utc_now()
      assert {:ok, []} = Issues.fetch_candidate_issues(request_fun: request_fun)
      assert_received {:open_issue_listing, "owner/repo", history_issues, listed_from}
      assert_received {:first_page_at, first_page_at}
      assert DateTime.compare(listed_from, first_page_at) != :gt
      assert Enum.map(history_issues, & &1.id) == ["7", "8"]
      assert DateTime.compare(listed_from, before_request) != :lt
      assert_received {:open_issues_recorded, first_time}
      assert DateTime.to_unix(listed_from, :millisecond) <= first_time
      assert {:ok, ^expected, ^first_time} = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
      assert_received {:list_request, ^base_url}
      assert_received {:list_request, ^second_url}
      refute_received {:list_request, _}
      assert {:ok, [], cache} = Issues.fetch_candidate_issues_conditional(%{}, request_fun: request_fun)
      assert_received {:open_issue_listing, "owner/repo", conditional_issues, conditional_from}
      assert Enum.map(conditional_issues, & &1.id) == ["7", "8"]
      assert Enum.map(conditional_issues, & &1.labels) == Enum.map(history_issues, & &1.labels)
      assert_received {:first_page_at, conditional_page_at}
      assert DateTime.compare(conditional_from, conditional_page_at) != :gt
      assert DateTime.compare(conditional_from, listed_from) != :lt
      assert_received {:open_issues_recorded, _}
      assert_received {:list_request, ^base_url}
      assert_received {:list_request, ^second_url}
      refute_received {:list_request, _}
      assert {:ok, [], _} = Issues.fetch_candidate_issues_conditional(cache, request_fun: request_fun)
      assert_received {:open_issue_listing, "owner/repo", cached_issues, cached_from}
      assert cached_issues == conditional_issues
      assert_received {:first_page_at, cached_page_at}
      assert DateTime.compare(cached_from, cached_page_at) != :gt
      assert DateTime.compare(cached_from, conditional_from) != :lt
      assert_received {:open_issues_recorded, cached_time}
      assert {:ok, ^expected, ^cached_time} = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
      assert_received {:list_request, ^base_url}
      assert_received {:list_request, ^second_url}
      refute_received {:list_request, _}

      failed_page = fn request ->
        if request.url == base_url, do: request_fun.(request), else: {:error, :timeout}
      end

      assert {:error, _} = Issues.fetch_candidate_issues_conditional(%{}, request_fun: failed_page)
      refute_received {:open_issue_listing, _, _, _}
      assert {:ok, ^expected, ^cached_time} = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
      refute_received {:open_issues_recorded, _}
    end
  end
end
