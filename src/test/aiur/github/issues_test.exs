defmodule Aiur.GitHub.IssuesTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Client
  alias Aiur.GitHub.Issues
  alias Aiur.Issue

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

  describe "fetch_issues_by_states/2" do
    test "direct conditional GitHub lists expose only pinned test tickets, including cached pages" do
      Aiur.TestScopeGuard.put_ticket_scope!("99")

      issue = fn number ->
        %{
          "number" => number,
          "title" => "Issue #{number}",
          "body" => nil,
          "html_url" => "https://github.com/owner/repo/issues/#{number}",
          "labels" => [%{"name" => "sym:ci-wait"}],
          "assignee" => nil,
          "created_at" => "2026-01-01T00:00:00Z",
          "updated_at" => "2026-01-02T00:00:00Z"
        }
      end

      parent = self()

      request_fun = fn
        %{url: url, etag: _etag} ->
          assert url =~ "/issues?labels="
          {:ok, %{status: 304}}

        %{url: url} ->
          if url =~ "/timeline" do
            send(parent, {:timeline_requested, url})
            {:ok, %{status: 200, headers: [], body: []}}
          else
            {:ok, %{status: 200, headers: [{"etag", "list-v1"}], body: [issue.(99), issue.(2413)]}}
          end
      end

      assert {:ok, [%Issue{identifier: "99"}], cache} =
               Client.fetch_issues_by_states_conditional(["ci-wait"], %{}, request_fun: request_fun)

      assert_received {:timeline_requested, "https://api.github.com/repos/owner/repo/issues/99/timeline?per_page=50"}
      refute_received {:timeline_requested, "https://api.github.com/repos/owner/repo/issues/2413/timeline?per_page=50"}

      assert {:ok, [%Issue{identifier: "99"}], _cache} =
               Client.fetch_issues_by_states_conditional(["ci-wait"], cache, request_fun: request_fun)

      System.delete_env("AIUR_DEV_TEST_TICKET_IDS")

      assert {:ok, issues, _cache} =
               Client.fetch_issues_by_states_conditional(["ci-wait"], cache, request_fun: request_fun)

      assert Enum.map(issues, & &1.identifier) |> Enum.sort() == ["2413", "99"]

      Aiur.TestScopeGuard.put_ticket_scope!("")
      assert_raise ArgumentError, fn -> Aiur.TestTicketScope.validate!() end
    end

    test "returns empty list when no states given" do
      assert {:ok, []} = Issues.fetch_issues_by_states([])
    end

    test "fetches issues for each state label" do
      request_fun = fn %{method: :get, url: url} ->
        if URI.decode(url) =~ "labels=sym:todo" do
          issue = %{
            "number" => 7,
            "title" => "A todo issue",
            "body" => nil,
            "html_url" => "https://github.com/owner/repo/issues/7",
            "labels" => [%{"name" => "sym:todo"}],
            "assignee" => nil,
            "created_at" => "2026-01-01T00:00:00Z",
            "updated_at" => "2026-01-02T00:00:00Z"
          }

          pull_request =
            issue
            |> Map.put("number", 8)
            |> Map.put("title", "A pull request with the same label")
            |> Map.put("html_url", "https://github.com/owner/repo/pull/8")
            |> Map.put("pull_request", %{"url" => "https://api.github.com/repos/owner/repo/pulls/8"})

          {:ok, %{status: 200, headers: [{"etag", "\"issue-list-v1\""}], body: [issue, pull_request]}}
        else
          {:ok, %{status: 200, body: []}}
        end
      end

      assert {:ok, [issue]} = Issues.fetch_issues_by_states(["todo"], request_fun: request_fun)
      assert issue.id == "7"
      assert issue.state == "todo"
      assert issue.dispatch_revision == "\"issue-list-v1\""
    end

    test "follows Link rel=next so CI lifecycle states are not silently omitted" do
      issue = fn number ->
        %{
          "number" => number,
          "title" => "CI issue #{number}",
          "body" => nil,
          "html_url" => "https://github.com/owner/repo/issues/#{number}",
          "labels" => [%{"name" => "sym:ci-wait"}],
          "assignee" => nil,
          "created_at" => "2026-01-01T00:00:00Z",
          "updated_at" => "2026-01-02T00:00:00Z"
        }
      end

      request_fun = fn %{method: :get, url: url} ->
        if String.contains?(url, "page=2") do
          {:ok, %{status: 200, headers: [], body: [issue.(200)]}}
        else
          next =
            ~s(<https://api.github.com/repos/owner/repo/issues?labels=sym%3Aci-wait&state=open&per_page=100&page=2>; rel="next")

          {:ok, %{status: 200, headers: [{"link", next}], body: [issue.(100)]}}
        end
      end

      assert {:ok, issues} = Issues.fetch_issues_by_states(["ci-wait"], request_fun: request_fun)
      assert Enum.map(issues, & &1.id) |> MapSet.new() == MapSet.new(["100", "200"])
    end

    test "reuses every cached page after conditional responses" do
      issue = fn number ->
        %{
          "number" => number,
          "title" => "Issue #{number}",
          "body" => nil,
          "html_url" => "https://github.com/owner/repo/issues/#{number}",
          "labels" => [%{"name" => "sym:ci-wait"}],
          "assignee" => nil,
          "created_at" => "2026-01-01T00:00:00Z",
          "updated_at" => "2026-01-02T00:00:00Z"
        }
      end

      page_one =
        "https://api.github.com/repos/owner/repo/issues?labels=sym%3Aci-wait&state=open&per_page=100"

      page_two = page_one <> "&page=2"

      cache = %{
        "sym:ci-wait" => %{
          pages: %{
            page_one => %{
              etag: "one",
              issues: [Issues.normalize_issue(issue.(1), "owner", "repo", "sym")],
              next_url: page_two
            },
            page_two => %{
              etag: "two",
              issues: [Issues.normalize_issue(issue.(2), "owner", "repo", "sym")],
              next_url: nil
            }
          }
        }
      }

      request_fun = fn
        %{url: url, etag: etag} ->
          assert {url, etag} in [{page_one, "one"}, {page_two, "two"}]
          {:ok, %{status: 304}}

        # Dispatch authorization reads each issue's timeline to find who applied
        # the trigger label. Unconditional requests reaching this clause are the
        # proof that the conditional path still authorizes.
        %{url: url} ->
          assert url =~ "/timeline"
          {:ok, %{status: 200, headers: [], body: []}}
      end

      assert {:ok, issues, updated_cache} =
               Issues.fetch_issues_by_states_conditional(["ci-wait"], cache, request_fun: request_fun)

      assert Enum.map(issues, & &1.id) |> Enum.sort() == ["1", "2"]
      assert updated_cache == cache
    end

    # Regression guard: the conditional path once returned `Map.values(...)`
    # without `authorize_dispatches/6`. `normalize_issue/5` defaults
    # `dispatch_authorized?: false`, so `DispatchPolicy.candidate_issue?/3`
    # rejected every issue and the daemon silently dispatched nothing.
    test "authorizes dispatch on the conditional path just like the unconditional one" do
      gh_issue = %{
        "number" => 7,
        "title" => "Issue 7",
        "body" => nil,
        "html_url" => "https://github.com/owner/repo/issues/7",
        "labels" => [%{"name" => "sym:ci-wait"}],
        "assignee" => nil,
        "user" => %{"login" => "its-everdred"},
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      # Dispatch authorization has no creator short-circuit: it always verifies
      # who applied the trigger label, so the timeline has to carry a real
      # `labeled` event by a trusted actor for either path to authorize. Serving
      # the issue payload for `/timeline` would deny both paths and make the
      # parity assertion below pass trivially on `[false, false]`.
      labeled_event = %{
        "id" => 1,
        "event" => "labeled",
        "label" => %{"name" => "sym:ci-wait"},
        "actor" => %{"login" => "its-everdred"},
        "created_at" => "2026-01-01T00:00:00Z"
      }

      request_fun = fn
        %{url: url, etag: _etag} ->
          assert url =~ "/issues?labels="
          {:ok, %{status: 200, headers: [], body: [gh_issue]}}

        %{url: url} ->
          assert url =~ "/issues?labels=" or url =~ "/timeline"

          if url =~ "/timeline" do
            {:ok, %{status: 200, headers: [], body: [labeled_event]}}
          else
            {:ok, %{status: 200, headers: [], body: [gh_issue]}}
          end
      end

      assert {:ok, conditional_issues, _cache} =
               Issues.fetch_issues_by_states_conditional(["ci-wait"], %{}, request_fun: request_fun)

      assert {:ok, unconditional_issues} =
               Issues.fetch_issues_by_states(["ci-wait"], request_fun: request_fun)

      assert Enum.map(conditional_issues, & &1.dispatch_authorized?) ==
               Enum.map(unconditional_issues, & &1.dispatch_authorized?)

      assert [true] = Enum.map(conditional_issues, & &1.dispatch_authorized?)
    end
  end
end
