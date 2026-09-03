defmodule Aiur.GitHub.IssuesTest do
  use Aiur.TestSupport

  alias Aiur.{GitHub.Issues, Issue}

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

  describe "fetch_candidate_issues/1" do
    test "revalidates one authoritative list and reuses it only on 304" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "sym",
        tracker_active_states: ["Todo", "In Progress"]
      )

      issue = fn number, state ->
        labels = if is_binary(state), do: [%{"name" => "sym:#{state}"}], else: []

        %{
          "number" => number,
          "title" => "Mutable label",
          "body" => nil,
          "html_url" => "https://github.com/owner/repo/issues/#{number}",
          "labels" => labels,
          "assignee" => nil,
          "created_at" => "2026-01-01T00:00:00Z",
          "updated_at" => "2026-01-02T00:00:00Z"
        }
      end

      stale_page = [issue.(42, "in-progress"), issue.(43, "done"), issue.(44, nil)]
      fresh_page = [issue.(42, "todo"), issue.(43, "done"), issue.(44, nil)]
      {:ok, list_step} = Agent.start_link(fn -> 0 end)

      request_fun = fn request ->
        if String.ends_with?(request.url, "/timeline?per_page=100") do
          {:ok, %{status: 200, headers: [], body: []}}
        else
          assert request.url == "https://api.github.com/repos/owner/repo/issues?state=open&per_page=100"
          # The open-issue list is bound by its own, larger cap (#2140); the
          # single-issue cap would truncate a growing backlog.
          assert request.max_response_bytes == 1_048_576

          Agent.get_and_update(list_step, fn
            0 ->
              refute Map.has_key?(request, :etag)
              {{:ok, %{status: 200, headers: [{"etag", "v1"}], body: stale_page}}, 1}

            1 ->
              assert request.etag == "v1"
              {{:ok, %{status: 200, headers: [{"etag", "v2"}], body: fresh_page}}, 2}

            2 ->
              assert request.etag == "v2"
              {{:ok, %{status: 304}}, 3}
          end)
        end
      end

      # The conditional path (the orchestrator's dispatch poll) partitions
      # rather than discards: the zero-label issue 44 is returned alongside the
      # authorized dispatch candidate 42 so the repair pass can heal it (#2420).
      # The terminal-labelled issue 43 is still dropped.
      assert {:ok, issues, cache} =
               Issues.fetch_candidate_issues_conditional(%{}, request_fun: request_fun)

      assert Enum.map(issues, & &1.id) == ["42", "44"]
      assert Enum.find(issues, &(&1.id == "42")).state == "in-progress"
      assert Enum.find(issues, &(&1.id == "44")).state_labels == []

      assert {:ok, issues, cache} =
               Issues.fetch_candidate_issues_conditional(cache, request_fun: request_fun)

      assert Enum.map(issues, & &1.id) == ["42", "44"]
      assert Enum.find(issues, &(&1.id == "42")).state == "todo"

      assert {:ok, issues, _cache} =
               Issues.fetch_candidate_issues_conditional(cache, request_fun: request_fun)

      assert Enum.map(issues, & &1.id) == ["42", "44"]

      assert Agent.get(list_step, & &1) == 3
    end

    test "the conditional path surfaces degenerate tickets for repair but excludes pull requests" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "sym",
        tracker_active_states: ["todo", "in-progress"]
      )

      issue = fn number, labels ->
        %{
          "number" => number,
          "title" => "Issue #{number}",
          "body" => nil,
          "html_url" => "https://github.com/owner/repo/issues/#{number}",
          "labels" => labels,
          "assignee" => nil,
          "created_at" => "2026-01-01T00:00:00Z",
          "updated_at" => "2026-01-02T00:00:00Z"
        }
      end

      page = [
        issue.(50, [%{"name" => "sym:todo"}]),
        issue.(51, []),
        issue.(52, [%{"name" => "sym:in-progress"}, %{"name" => "sym:rework"}]),
        Map.put(issue.(53, []), "pull_request", %{"url" => "https://api.github.com/repos/owner/repo/pulls/53"})
      ]

      {:ok, list_step} = Agent.start_link(fn -> 0 end)

      # Dispatch authorization needs a labeled timeline event for the
      # dispatchable candidate; the degenerate tickets must not be authorized.
      request_fun = fn request ->
        if String.ends_with?(request.url, "/timeline?per_page=100") do
          labeled_event = %{
            "id" => 1,
            "event" => "labeled",
            "label" => %{"name" => "sym:todo"},
            "actor" => %{"login" => "its-everdred"},
            "created_at" => "2026-01-01T00:00:00Z"
          }

          {:ok, %{status: 200, headers: [], body: [labeled_event]}}
        else
          assert request.url == "https://api.github.com/repos/owner/repo/issues?state=open&per_page=100"

          Agent.get_and_update(list_step, fn
            0 -> {{:ok, %{status: 200, headers: [{"etag", "v1"}], body: page}}, 1}
            1 -> {{:ok, %{status: 304}}, 2}
          end)
        end
      end

      assert {:ok, issues, cache} =
               Issues.fetch_candidate_issues_conditional(%{}, request_fun: request_fun)

      ids = Enum.map(issues, & &1.id)
      assert "50" in ids
      assert "51" in ids
      assert "52" in ids
      refute "53" in ids

      # The zero-label (51) and contradictory-label (52) tickets keep their
      # degenerate state_labels so the orchestrator's repair pass can heal
      # them; only the dispatch candidate (50) is authorized.
      assert Enum.find(issues, &(&1.id == "51")).state_labels == []
      assert Enum.find(issues, &(&1.id == "52")).state_labels == ["in-progress", "rework"]
      assert Enum.find(issues, &(&1.id == "50")).dispatch_authorized?
      refute Enum.find(issues, &(&1.id == "51")).dispatch_authorized?
      refute Enum.find(issues, &(&1.id == "52")).dispatch_authorized?

      assert {:ok, cached_issues, _cache} =
               Issues.fetch_candidate_issues_conditional(cache, request_fun: request_fun)

      assert Enum.map(cached_issues, & &1.id) == ids
      assert Agent.get(list_step, & &1) == 2
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

  describe "fetch_issue_raw_conditional/2" do
    test "returns raw map on 200 with the :fetched outcome" do
      raw_body = %{"number" => 5, "title" => "Raw"}

      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/issues/5"
        {:ok, %{status: 200, body: raw_body, headers: []}}
      end

      assert {:ok, ^raw_body, :fetched} = Issues.fetch_issue_raw_conditional(5, request_fun: request_fun)
    end

    test "returns error on non-200 status" do
      request_fun = fn _ -> {:ok, %{status: 404, body: %{"message" => "Not Found"}, headers: []}} end
      assert {:error, _} = Issues.fetch_issue_raw_conditional(999, request_fun: request_fun)
    end

    test "uses an explicit validated repository instead of the configured fallback" do
      request_fun = fn %{url: url} ->
        assert url == "https://api.github.com/repos/explicit/repository/issues/5"
        {:ok, %{status: 200, body: %{}, headers: []}}
      end

      assert {:ok, %{}, _outcome} =
               Issues.fetch_issue_raw_conditional(5,
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
                 Issues.fetch_issue_raw_conditional(5,
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

    # Quarantined for #2397: this integration test reads `configured_repo/0`
    # through the shared `WorkflowStore` singleton, and under load the store can
    # serve the previous (valid) config for this path right after the malformed
    # write + `force_reload` — CI run 32630000223 caught it returning a
    # `:joinable` identity with `owner/repo`. The same shape reproduces locally
    # (~2%) when this module runs immediately after `workflow_store_test.exs`,
    # which manipulates the shared cache directly. The exact residual-state
    # mechanism is not yet pinned down; the behavior stays covered by the
    # deterministic pure-layer test in `tracker_identity_test.exs`, and the
    # quarantine job keeps this integration path exercised non-blockingly so a
    # regression still surfaces.
    @tag :quarantine
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

    test "resolves contradictory workflow state labels deterministically" do
      # A ticket carrying two `agent:*` state labels is a broken lifecycle state.
      # `extract_state` resolves it deterministically (todo wins; otherwise the
      # most-outstanding-work non-ci-wait label wins) so no consumer sees a nil
      # state and a stale `agent:ci-wait` can never outlive its CI run (#2366).
      gh = %{
        "number" => 18,
        "title" => "Contradictory labels",
        "labels" => [%{"name" => "sym:error"}, %{"name" => "sym:todo"}],
        "state" => "open"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")

      assert issue.state == "todo"
      assert issue.state_labels == ["error", "todo"]
    end

    test "resolves two real dispositions by most-outstanding-work precedence" do
      # Mirror of `DispatchPolicy.resolve_state_labels/1` (#2366): two labels
      # that both assert a real disposition resolve by the explicit precedence
      # order, not alphabetical order — `done` + `rework` is `rework`, never
      # `done`, so the heal never closes a ticket whose work is outstanding.
      for {labels, expected} <- [
            {["done", "rework"], "rework"},
            {["rework", "done"], "rework"},
            {["error", "rework"], "rework"},
            {["done", "in-progress"], "in-progress"},
            {["rework", "in-progress"], "rework"}
          ] do
        gh = %{
          "number" => 21,
          "title" => "Real dispositions",
          "labels" => Enum.map(labels, &%{"name" => "sym:#{&1}"}),
          "state" => "open"
        }

        assert Issues.extract_state(gh, Enum.map(labels, &"sym:#{&1}"), "sym") == expected
        assert Issues.normalize_issue(gh, "owner", "repo", "sym").state == expected
      end
    end

    test "resolves a ci-wait pair to the real disposition, never ci-wait" do
      # `ci-wait` is a transient sub-state and never wins a resolution: a
      # `ci-wait`+`rework` ticket is really rework, a `ci-wait`+`human-review`
      # ticket is really in review (#2366).
      for {labels, expected} <- [
            {["rework", "ci-wait"], "rework"},
            {["ci-wait", "human-review"], "human-review"},
            {["ci-wait"], "ci-wait"}
          ] do
        gh = %{"number" => 20, "title" => "ci-wait pair", "labels" => Enum.map(labels, &%{"name" => "sym:#{&1}"}), "state" => "open"}
        assert Issues.normalize_issue(gh, "owner", "repo", "sym").state == expected
      end
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

  describe "fetch_issue_states_by_ids_conditional/3" do
    test "sends a stored per-issue etag in the next cycle and materializes a 304" do
      {:ok, request_count} = Agent.start_link(fn -> 0 end)

      gh_issue = %{
        "number" => 42,
        "title" => "Fix bug",
        "body" => "desc",
        "html_url" => "https://github.com/owner/repo/issues/42",
        "labels" => [%{"name" => "sym:in-progress"}],
        "assignee" => %{"login" => "dev"},
        "user" => %{"login" => "its-everdred"},
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      request_fun = fn %{url: url} = request ->
        cond do
          String.ends_with?(url, "/issues/42") ->
            case Agent.get_and_update(request_count, &{&1, &1 + 1}) do
              0 ->
                refute Map.has_key?(request, :etag)
                {:ok, %{status: 200, headers: [{"etag", ~s("issue-42-v1")}], body: gh_issue}}

              1 ->
                assert request.etag == ~s("issue-42-v1")
                {:ok, %{status: 304, headers: [], body: ""}}
            end

          String.ends_with?(url, "/issues/42/timeline?per_page=100") ->
            {:ok, %{status: 200, headers: [], body: []}}
        end
      end

      assert {:ok, [first_issue], first_cache} =
               Issues.fetch_issue_states_by_ids_conditional(["42"], %{}, request_fun: request_fun)

      assert {:ok, [second_issue], second_cache} =
               Issues.fetch_issue_states_by_ids_conditional(["42"], first_cache, request_fun: request_fun)

      assert first_issue == second_issue
      assert Map.keys(first_cache) == ["42"]
      assert second_cache == first_cache
      assert Agent.get(request_count, & &1) == 2
    end

    test "re-authorizes a cached issue against the current allowlist after a 304" do
      codeowners = Aiur.GitHub.CodeOwners
      previous_state = :sys.get_state(codeowners)

      on_exit(fn ->
        if Process.whereis(codeowners), do: :sys.replace_state(codeowners, fn _ -> previous_state end)
      end)

      :sys.replace_state(codeowners, fn state ->
        %{state | codeowners: MapSet.new(["trusted-labeler"])}
      end)

      {:ok, issue_request_count} = Agent.start_link(fn -> 0 end)

      gh_issue = %{
        "number" => 142,
        "title" => "Refresh authorization",
        "body" => "desc",
        "html_url" => "https://github.com/owner/repo/issues/142",
        "labels" => [%{"name" => "sym:in-progress"}],
        "user" => %{"login" => "anyone"},
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-03T00:00:00Z"
      }

      # Authorization is decided by the verified applier of the trigger label,
      # so the timeline has to carry a real `labeled` event.
      labeled_event = %{
        "id" => 1,
        "event" => "labeled",
        "label" => %{"name" => "sym:in-progress"},
        "actor" => %{"login" => "trusted-labeler"},
        "created_at" => "2026-01-01T00:00:00Z"
      }

      request_fun = fn %{url: url} = request ->
        cond do
          String.ends_with?(url, "/issues/142") ->
            case Agent.get_and_update(issue_request_count, &{&1, &1 + 1}) do
              0 ->
                refute Map.has_key?(request, :etag)
                {:ok, %{status: 200, headers: [{"etag", ~s("issue-142-v1")}], body: gh_issue}}

              1 ->
                assert request.etag == ~s("issue-142-v1")
                {:ok, %{status: 304, headers: [], body: ""}}
            end

          String.ends_with?(url, "/issues/142/timeline?per_page=100") ->
            {:ok, %{status: 200, headers: [], body: [labeled_event]}}
        end
      end

      assert {:ok, [%Aiur.Issue{dispatch_authorized?: true}], first_cache} =
               Issues.fetch_issue_states_by_ids_conditional(["142"], %{}, request_fun: request_fun)

      :sys.replace_state(codeowners, fn state ->
        %{state | codeowners: MapSet.new(["replacement-owner"])}
      end)

      assert {:ok, [%Aiur.Issue{dispatch_authorized?: false}], second_cache} =
               Issues.fetch_issue_states_by_ids_conditional(["142"], first_cache, request_fun: request_fun)

      assert second_cache["142"].etag == ~s("issue-142-v1")
      refute second_cache["142"].issue.dispatch_authorized?
      assert Agent.get(issue_request_count, & &1) == 2
    end

    test "evicts a cached issue after a conditional 404" do
      cached_issue = %Aiur.Issue{id: "42", identifier: "42", title: "Cached"}
      cache = %{"42" => %{etag: ~s("issue-42-v1"), issue: cached_issue}}

      request_fun = fn request ->
        assert request.url =~ "/issues/42"
        assert request.etag == ~s("issue-42-v1")
        {:ok, %{status: 404, headers: [], body: %{"message" => "Not Found"}}}
      end

      assert {:ok, [], %{}} =
               Issues.fetch_issue_states_by_ids_conditional(["42"], cache, request_fun: request_fun)
    end

    test "retries without the cache and fails closed when a 304 has no materialized issue" do
      {:ok, request_count} = Agent.start_link(fn -> 0 end)

      # An etag with no materialized issue should never occur: both are written
      # together. If it ever does, omitting the issue from the result list is
      # unsafe -- Reconciler.reconcile_missing_running_issue_ids/3 reads absence
      # as "no longer visible" and terminates the running agent. Fail closed so
      # the reconciler takes its keep-active-workers path instead.
      cache = %{"42" => %{etag: ~s("issue-42-v1")}}

      request_fun = fn request ->
        case Agent.get_and_update(request_count, &{&1, &1 + 1}) do
          0 ->
            assert request.etag == ~s("issue-42-v1")
            {:ok, %{status: 304, headers: [], body: ""}}

          1 ->
            refute Map.has_key?(request, :etag)
            {:ok, %{status: 304, headers: [], body: ""}}
        end
      end

      assert {:error, :github_issue_not_modified_without_cached_value, _cache} =
               Issues.fetch_issue_states_by_ids_conditional(["42"], cache, request_fun: request_fun)

      assert Agent.get(request_count, & &1) == 2
    end

    test "returns successful per-issue cache updates when a later request fails" do
      gh_issue = %{
        "number" => 42,
        "title" => "Fix bug",
        "body" => "desc",
        "html_url" => "https://github.com/owner/repo/issues/42",
        "labels" => [%{"name" => "sym:in-progress"}],
        "user" => %{"login" => "its-everdred"},
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      request_fun = fn %{url: url} ->
        if String.ends_with?(url, "/42") do
          {:ok, %{status: 200, headers: [{"etag", ~s("issue-42-v1")}], body: gh_issue}}
        else
          {:error, :timeout}
        end
      end

      assert {:error, _reason, cache} =
               Issues.fetch_issue_states_by_ids_conditional(["42", "43"], %{}, request_fun: request_fun)

      assert %{
               "42" => %{etag: ~s("issue-42-v1"), issue: %Aiur.Issue{id: "42"}}
             } = cache
    end
  end
end
