defmodule Aiur.GitHub.IssuesTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Issues

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
    test "returns empty list when no states given" do
      assert {:ok, []} = Issues.fetch_issues_by_states([])
    end

    test "fetches issues for each state label" do
      request_fun = fn %{method: :get, url: url} ->
        if URI.decode(url) =~ "labels=sym:todo" do
          body = [
            %{
              "number" => 7,
              "title" => "A todo issue",
              "body" => nil,
              "html_url" => "https://github.com/owner/repo/issues/7",
              "labels" => [%{"name" => "sym:todo"}],
              "assignee" => nil,
              "created_at" => "2026-01-01T00:00:00Z",
              "updated_at" => "2026-01-02T00:00:00Z"
            }
          ]

          {:ok, %{status: 200, headers: [{"etag", "\"issue-list-v1\""}], body: body}}
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

  describe "fetch_issue_states_by_ids/2" do
    test "returns empty list for empty id list" do
      assert {:ok, []} = Issues.fetch_issue_states_by_ids([])
    end

    test "fetches issues by numeric id via individual requests" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/issues/42"

        body = %{
          "number" => 42,
          "title" => "Fix bug",
          "body" => "desc",
          "html_url" => "https://github.com/owner/repo/issues/42",
          "labels" => [%{"name" => "sym:in-progress"}],
          "assignee" => %{"login" => "dev"},
          "created_at" => "2026-01-01T00:00:00Z",
          "updated_at" => "2026-01-02T00:00:00Z"
        }

        {:ok, %{status: 200, body: body}}
      end

      assert {:ok, [issue]} =
               Issues.fetch_issue_states_by_ids(["42"], request_fun: request_fun)

      assert issue.id == "42"
      assert issue.assignee_id == "dev"
    end
  end

  describe "hydrate_blocked_by/1" do
    # Regression for #1631. The GitHub list poll never populates `blocked_by`
    # (each dependency read is a separate REST call, so per-issue hydration on
    # the poll path would blow the read budget). The production chain is:
    # `normalize_issue/4` → `blocked_by: []` → hydration on the dispatch /
    # dependency-pause recheck path. Older tests hand-built `blocked_by`
    # directly, which the production GitHub path can never exhibit — this test
    # goes through `normalize_issue/4` instead, so the exact blind spot is not
    # rebuilt.
    test "hydrates native blockers onto a polled issue (normalize_issue leaves blocked_by empty)" do
      gh = %{
        "number" => 10,
        "node_id" => "I_kwDOIssue10",
        "title" => "Test issue",
        "body" => "body text",
        "html_url" => "https://github.com/owner/repo/issues/10",
        "labels" => [%{"name" => "sym:todo"}],
        "user" => %{"login" => "creator"},
        "assignee" => %{"login" => "alice"},
        "state" => "open",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      polled = Issues.normalize_issue(gh, "owner", "repo", "sym")
      assert polled.blocked_by == []

      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/issues/10/dependencies/blocked_by"

        {:ok,
         %{
           status: 200,
           body: [
             %{
               "number" => 3,
               "html_url" => "https://github.com/owner/repo/issues/3",
               "state" => "open",
               "labels" => [%{"name" => "sym:in-progress"}]
             }
           ]
         }}
      end

      assert {:ok, %Issue{blocked_by: [blocker]}} =
               Issues.hydrate_blocked_by(polled, request_fun: request_fun)

      assert blocker.id == "3"
      assert blocker.identifier == "3"
      assert blocker.state == "in-progress"
      assert blocker.url == "https://github.com/owner/repo/issues/3"
    end

    test "returns the issue unchanged when blocked_by is already hydrated" do
      issue = %Issue{id: "5", identifier: "5", title: "t", state: "todo", blocked_by: [%{id: "2", state: "done"}]}

      assert {:ok, ^issue} = Issues.hydrate_blocked_by(issue)
    end

    test "fetches and normalizes native blockers onto the issue" do
      request_fun = fn %{method: :get, url: url, api_version: api_version} ->
        assert url =~ "/issues/5/dependencies/blocked_by"
        assert api_version == "2026-03-10"

        blockers = [
          %{
            "number" => 3,
            "html_url" => "https://github.com/owner/repo/issues/3",
            "state" => "open",
            "labels" => [%{"name" => "sym:todo"}]
          },
          %{
            "number" => 4,
            "html_url" => "https://github.com/owner/repo/issues/4",
            "state" => "closed",
            "labels" => []
          }
        ]

        {:ok, %{status: 200, body: blockers}}
      end

      issue = %Issue{id: "5", identifier: "5", title: "t", state: "todo"}

      assert {:ok, %Issue{blocked_by: blockers}} =
               Issues.hydrate_blocked_by(issue, request_fun: request_fun)

      assert blockers == [
               %{
                 id: "3",
                 identifier: "3",
                 state: "todo",
                 url: "https://github.com/owner/repo/issues/3"
               },
               %{
                 id: "4",
                 identifier: "4",
                 state: "Closed",
                 url: "https://github.com/owner/repo/issues/4"
               }
             ]
    end

    test "an open blocker with no agent state label hydrates as unknown (fail-closed at the gate)" do
      request_fun = fn %{method: :get, url: _url} ->
        {:ok, %{status: 200, body: [%{"number" => 9, "state" => "open", "labels" => []}]}}
      end

      issue = %Issue{id: "5", identifier: "5", title: "t", state: "todo"}

      assert {:ok, %Issue{blocked_by: [blocker]}} =
               Issues.hydrate_blocked_by(issue, request_fun: request_fun)

      assert blocker.id == "9"
      assert blocker.state == nil
    end

    test "returns the error when the dependency read fails" do
      request_fun = fn %{method: :get, url: _url} ->
        {:ok, %{status: 500, body: %{"message" => "boom"}}}
      end

      issue = %Issue{id: "5", identifier: "5", title: "t", state: "todo"}

      assert {:error, {:github, :http, %{status: 500}}} =
               Issues.hydrate_blocked_by(issue, request_fun: request_fun)
    end

    test "returns the error on 403/429 rate-limit responses (fail-closed, never blocked_by: [])" do
      issue = %Issue{id: "5", identifier: "5", title: "t", state: "todo"}

      forbidden =
        fn %{method: :get, url: _url} ->
          {:ok, %{status: 403, body: %{"message" => "forbidden"}}}
        end

      assert {:error, {:github, _classification, %{status: 403}}} =
               Issues.hydrate_blocked_by(issue, request_fun: forbidden)

      rate_limited =
        fn %{method: :get, url: _url} ->
          {:ok, %{status: 429, body: %{"message" => "rate limited"}}}
        end

      assert {:error, {:github, :rate_limited, %{status: 429}}} =
               Issues.hydrate_blocked_by(issue, request_fun: rate_limited)
    end

    test "returns the error on transport/timeout failures (fail-closed)" do
      request_fun = fn %{method: :get, url: _url} -> {:error, :timeout} end

      issue = %Issue{id: "5", identifier: "5", title: "t", state: "todo"}

      assert {:error, {:github, :timeout, %{reason: :timeout}}} =
               Issues.hydrate_blocked_by(issue, request_fun: request_fun)
    end

    test "returns the issue unchanged when it has no numeric id" do
      issue = %Issue{id: nil, identifier: nil, title: "t", state: "todo"}

      assert {:ok, ^issue} = Issues.hydrate_blocked_by(issue)
    end
  end

  describe "fetch_issue_raw/2" do
    test "returns raw map on 200" do
      raw_body = %{"number" => 5, "title" => "Raw"}

      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/issues/5"
        {:ok, %{status: 200, body: raw_body}}
      end

      assert {:ok, ^raw_body} = Issues.fetch_issue_raw(5, request_fun: request_fun)
    end

    test "returns error on non-200 status" do
      request_fun = fn _ -> {:ok, %{status: 404, body: %{"message" => "Not Found"}}} end
      assert {:error, _} = Issues.fetch_issue_raw(999, request_fun: request_fun)
    end

    test "uses an explicit validated repository instead of the configured fallback" do
      request_fun = fn %{url: url} ->
        assert url == "https://api.github.com/repos/explicit/repository/issues/5"
        {:ok, %{status: 200, body: %{}}}
      end

      assert {:ok, %{}} =
               Issues.fetch_issue_raw(5,
                 repository: {"explicit", "repository"},
                 request_fun: request_fun
               )
    end

    test "rejects an invalid explicit repository before transport" do
      for repository <- [
            {"owner/repo", "repository"},
            {"owner?query", "repository"},
            {"owner", "repository#fragment"},
            {"owner name", "repository"},
            {"..", "repository"}
          ] do
        assert {:error, :invalid_github_repository} =
                 Issues.fetch_issue_raw(5,
                   repository: repository,
                   request_fun: fn _request -> flunk("transport must not be called") end
                 )
      end
    end
  end

  describe "normalize_issue/4" do
    test "maps github issue fields to Issue struct" do
      gh = %{
        "number" => 10,
        "node_id" => "I_kwDOIssue10",
        "title" => "Test issue",
        "body" => "body text",
        "html_url" => "https://github.com/owner/repo/issues/10",
        "labels" => [%{"name" => "sym:todo"}, %{"name" => "priority:1"}],
        "user" => %{"login" => "creator"},
        "assignee" => %{"login" => "alice"},
        "state" => "open",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")

      assert issue.id == "10"

      assert %{
               status: :joinable,
               kind: :github,
               owner: "owner",
               repository: "repo",
               provider_id: "I_kwDOIssue10",
               identifier: "10"
             } =
               issue.tracker_identity

      assert issue.title == "Test issue"
      assert issue.priority == 1
      assert issue.state == "todo"
      assert issue.assignee_id == "alice"
      assert issue.creator_login == "creator"
      refute issue.dispatch_authorized?
      assert issue.paused == false
    end

    test "marks repository-mismatched and missing-node responses explicitly nonjoinable" do
      mismatched = %{
        "number" => 14,
        "node_id" => "I_kwDOIssue14",
        "repository_url" => "https://api.github.com/repos/other/repo",
        "labels" => []
      }

      missing_node = %{"number" => 15, "title" => "Legacy response", "labels" => []}

      assert %{status: :unjoinable, reason: :repository_mismatch} =
               Issues.normalize_issue(mismatched, "owner", "repo", "sym").tracker_identity

      assert %{status: :unjoinable, reason: :missing_provider_identity, identifier: "15"} =
               Issues.normalize_issue(missing_node, "owner", "repo", "sym").tracker_identity
    end

    test "does not use the current checkout when repository configuration is absent" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: nil,
        tracker_label_prefix: "sym"
      )

      issue = %{"number" => 16, "node_id" => "I_kwDOIssue16", "labels" => []}

      assert %{status: :unjoinable, reason: :missing_configured_repository} =
               Issues.normalize_issue(issue, "owner", "repo", "sym").tracker_identity
    end

    test "marks malformed configured repositories explicitly nonjoinable" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo/extra",
        tracker_label_prefix: "sym"
      )

      issue = %{"number" => 17, "node_id" => "I_kwDOIssue17", "labels" => []}

      assert %{status: :unjoinable, reason: :invalid_configured_repository} =
               Issues.normalize_issue(issue, "owner", "repo", "sym").tracker_identity
    end

    test "marks closed issues with Closed state" do
      gh = %{
        "number" => 11,
        "title" => "Closed",
        "body" => nil,
        "html_url" => "https://github.com/owner/repo/issues/11",
        "labels" => [],
        "assignee" => nil,
        "state" => "closed",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")
      assert issue.state == "Closed"
    end

    test "marks paused issues" do
      gh = %{
        "number" => 12,
        "title" => "Paused",
        "body" => nil,
        "html_url" => "https://github.com/owner/repo/issues/12",
        "labels" => [%{"name" => "sym:paused"}, %{"name" => "sym:in-progress"}],
        "assignee" => nil,
        "state" => "open",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")
      assert issue.paused == true
      assert issue.state == "in-progress"
    end

    test "marks parked issues and keeps the marker out of workflow state selection" do
      # #1971: `agent:parked` is an explicit operator-held marker. Even when a
      # real state label is present, the ticket must read as parked (so dispatch
      # and comment-driven rework refuse it), and the marker must never be
      # mistaken for a workflow state itself.
      gh = %{
        "number" => 19,
        "title" => "Parked",
        "body" => nil,
        "html_url" => "https://github.com/owner/repo/issues/19",
        "labels" => [%{"name" => "sym:parked"}, %{"name" => "sym:todo"}],
        "assignee" => nil,
        "state" => "open",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")

      assert issue.parked == true
      assert issue.state == "todo"
      assert "sym:parked" in issue.labels
      refute "parked" in issue.state_labels
    end

    test "does not choose between contradictory workflow state labels" do
      gh = %{
        "number" => 18,
        "title" => "Contradictory labels",
        "labels" => [%{"name" => "sym:error"}, %{"name" => "sym:todo"}],
        "state" => "open"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")

      assert issue.state == nil
      assert issue.state_labels == ["error", "todo"]
    end

    test "keeps the fallback marker out of workflow state selection" do
      gh = %{
        "number" => 13,
        "title" => "Fallback",
        "body" => nil,
        "html_url" => "https://github.com/owner/repo/issues/13",
        "labels" => [%{"name" => "sym:rate-limit-fallback"}, %{"name" => "sym:in-progress"}],
        "assignee" => nil,
        "state" => "open",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")

      assert issue.state == "in-progress"
      assert "sym:rate-limit-fallback" in issue.labels
    end
  end

  describe "parse_datetime/1" do
    test "returns nil for nil" do
      assert Issues.parse_datetime(nil) == nil
    end

    test "parses ISO 8601 strings" do
      assert %DateTime{year: 2026} = Issues.parse_datetime("2026-01-01T00:00:00Z")
    end
  end
end
