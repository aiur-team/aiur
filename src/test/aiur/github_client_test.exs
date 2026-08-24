defmodule Aiur.GitHub.ClientTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{Client, DispatchAuthorization}
  alias Aiur.Workflow

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    DispatchAuthorization.clear_cache()
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

  describe "fetch_candidate_issues/1" do
    test "fetches one open snapshot and filters configured active states including rework" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "sym",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"]
      )

      parent = self()

      request_fun = fn %{method: :get, url: url} ->
        decoded_url = URI.decode(url)

        if decoded_url =~ "/timeline" do
          # Dispatch authorization checks trigger-label provenance after fetch.
          {:ok, %{status: 200, body: []}}
        else
          assert decoded_url =~ "/repos/owner/repo/issues?state=open&per_page=100"
          refute decoded_url =~ "labels="
          send(parent, :candidate_request)

          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 35,
                 "title" => "Fix review feedback",
                 "body" => nil,
                 "html_url" => "https://github.com/owner/repo/issues/35",
                 "labels" => [%{"name" => "sym:rework"}],
                 "assignee" => nil,
                 "created_at" => "2026-06-23T00:00:00Z",
                 "updated_at" => "2026-06-23T01:00:00Z"
               },
               %{
                 "number" => 36,
                 "title" => "Waiting for CI",
                 "body" => nil,
                 "html_url" => "https://github.com/owner/repo/issues/36",
                 "labels" => [%{"name" => "sym:ci-wait"}],
                 "assignee" => nil,
                 "created_at" => "2026-06-23T00:00:00Z",
                 "updated_at" => "2026-06-23T01:00:00Z"
               }
             ]
           }}
        end
      end

      assert {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)
      assert issue.id == "35"
      assert issue.state == "rework"

      assert_received :candidate_request
      refute_received :candidate_request
    end

    test "surfaces an issue carrying contradictory active-state labels as undispatchable" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "sym",
        tracker_active_states: ["in-progress", "rework"]
      )

      issue = fn ->
        %{
          "number" => 35,
          "title" => "Fix review feedback",
          "body" => nil,
          "html_url" => "https://github.com/owner/repo/issues/35",
          "labels" => [%{"name" => "sym:in-progress"}, %{"name" => "sym:rework"}],
          "assignee" => nil,
          "created_at" => "2026-06-23T00:00:00Z",
          "updated_at" => "2026-06-23T01:00:00Z"
        }
      end

      # The all-open snapshot returns each issue once. Contradictory state
      # labels resolve to a concrete state so no consumer sees a nil disposition
      # (and a stale `agent:ci-wait` can be cleared), but the pair must never
      # authorize dispatch: the ticket stays visible and undispatchable rather
      # than silently dropped from the pool as "no work" (#2366). The pair
      # resolves to the most-outstanding-work label (`rework`), never the
      # alphabetically-first one.
      request_fun = fn %{method: :get} -> {:ok, %{status: 200, body: [issue.()]}} end

      assert {:ok, [candidate]} = Client.fetch_candidate_issues(request_fun: request_fun)
      assert candidate.id == "35"
      assert candidate.state == "rework"
      assert candidate.state_labels == ["in-progress", "rework"]
      assert candidate.dispatch_authorized? == false
    end

    test "returns normalized issues from GitHub API" do
      request_fun = fn %{method: :get, url: url, token: token} ->
        assert token == "test-gh-token"
        assert url =~ "/repos/owner/repo/issues"

        cond do
          url =~ "/timeline" ->
            {:ok, %{status: 200, body: []}}

          URI.decode(url) =~ "/repos/owner/repo/issues?state=open&per_page=100" ->
            assert url =~ "state=open"
            refute URI.decode(url) =~ "labels="

            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "number" => 42,
                   "title" => "Fix the bug",
                   "body" => "Something is broken",
                   "html_url" => "https://github.com/owner/repo/issues/42",
                   "labels" => [
                     %{"name" => "sym:todo"},
                     %{"name" => "priority:1"}
                   ],
                   "assignee" => %{"login" => "dev1"},
                   "created_at" => "2025-01-01T00:00:00Z",
                   "updated_at" => "2025-01-02T00:00:00Z"
                 }
               ]
             }}

          true ->
            assert url =~ "state=open"
            {:ok, %{status: 200, body: []}}
        end
      end

      assert {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)
      assert issue.id == "42"
      assert issue.identifier == "42"
      assert issue.title == "Fix the bug"
      assert issue.description == "Something is broken"
      assert issue.state == "todo"
      assert issue.priority == 1
      assert issue.assignee_id == "dev1"
      assert issue.url == "https://github.com/owner/repo/issues/42"
    end

    test "deduplicates issues across labels" do
      request_fun = fn %{method: :get} ->
        {:ok,
         %{
           status: 200,
           body: [
             %{
               "number" => 42,
               "title" => "Dup",
               "body" => nil,
               "html_url" => "https://github.com/owner/repo/issues/42",
               "labels" => [%{"name" => "sym:todo"}],
               "assignee" => nil,
               "created_at" => "2025-01-01T00:00:00Z",
               "updated_at" => "2025-01-01T00:00:00Z"
             }
           ]
         }}
      end

      assert {:ok, [_single]} = Client.fetch_candidate_issues(request_fun: request_fun)
    end

    test "returns error on API failure" do
      request_fun = fn _ ->
        {:ok, %{status: 401}}
      end

      assert {:error, {:github, :auth, %{status: 401}}} =
               Client.fetch_candidate_issues(request_fun: request_fun)
    end

    test "returns error when token is missing" do
      System.delete_env("GITHUB_TOKEN")
      assert {:error, :missing_github_token} = Client.fetch_candidate_issues()
    end
  end

  describe "preflight_auth/1" do
    test "checks rate limit, repository, and issues endpoints with the active token" do
      parent = self()

      request_fun = fn %{method: :get, url: url, token: token} ->
        assert token == "test-gh-token"
        send(parent, {:preflight_url, url})
        {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "42"}], body: %{}}}
      end

      assert :ok =
               Client.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :not_installed} end
               )

      assert_received {:preflight_url, "https://api.github.com/rate_limit"}
      assert_received {:preflight_url, "https://api.github.com/repos/owner/repo"}

      assert_received {:preflight_url, "https://api.github.com/repos/owner/repo/issues?state=open&per_page=1"}
    end

    test "reports invalid GITHUB_TOKEN without leaking token material" do
      request_fun = fn %{url: url} ->
        if url =~ "/rate_limit" do
          {:ok, %{status: 401, headers: [], body: %{"message" => "Bad credentials"}}}
        else
          flunk("preflight should stop after the failed endpoint")
        end
      end

      assert {:error, {:github_auth_preflight_failed, diagnostic}} =
               Client.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :available} end
               )

      assert diagnostic.reason == :invalid_or_expired_token
      assert diagnostic.endpoint == :rate_limit
      assert diagnostic.status == 401
      assert diagnostic.gh_keyring_status == :available
      assert diagnostic.message =~ "GITHUB_TOKEN"
      assert diagnostic.message =~ "takes precedence over `gh` keyring auth"
      assert diagnostic.message =~ "gh` keyring auth appears usable"
      refute diagnostic.message =~ "test-gh-token"
    end

    test "fails when the REST core rate limit is exhausted" do
      reset = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_unix()

      request_fun = fn %{url: url} ->
        assert url =~ "/rate_limit"

        {:ok,
         %{
           status: 200,
           headers: [
             {"x-ratelimit-remaining", "0"},
             {"x-ratelimit-reset", Integer.to_string(reset)}
           ],
           body: %{"resources" => %{"core" => %{"remaining" => 0}}}
         }}
      end

      assert {:error, {:github_auth_preflight_failed, diagnostic}} =
               Client.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :unavailable} end
               )

      assert diagnostic.reason == :rate_limited
      assert diagnostic.rate_limit_remaining == 0
      assert diagnostic.message =~ "rate limit is exhausted"
      assert diagnostic.message =~ "GITHUB_TOKEN"
    end

    test "classifies DNS request failures during preflight" do
      request_fun = fn %{url: url} ->
        assert url =~ "/rate_limit"
        {:error, %Req.TransportError{reason: :nxdomain}}
      end

      assert {:error, {:github_auth_preflight_failed, diagnostic}} =
               Client.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :unavailable} end
               )

      assert diagnostic.reason == :dns
      assert diagnostic.classification == :dns
      assert diagnostic.detail == %{reason: :nxdomain}
      assert diagnostic.message =~ "DNS resolution failed"
      assert diagnostic.message =~ "api.github.com"
    end

    test "distinguishes endpoint-specific forbidden responses" do
      request_fun = fn %{url: url} ->
        cond do
          url =~ "/rate_limit" ->
            {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "42"}], body: %{}}}

          url =~ "/repos/owner/repo/issues" ->
            {:ok,
             %{
               status: 403,
               headers: [{"x-ratelimit-remaining", "42"}],
               body: %{"message" => "Resource not accessible by personal access token"}
             }}

          url =~ "/repos/owner/repo" ->
            {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "42"}], body: %{}}}
        end
      end

      assert {:error, {:github_auth_preflight_failed, diagnostic}} =
               Client.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :not_installed} end
               )

      assert diagnostic.reason == :forbidden
      assert diagnostic.endpoint == :issues
      assert diagnostic.rate_limit_remaining == 42
      assert diagnostic.message =~ "missing repository permissions"
      assert diagnostic.message =~ "repos/owner/repo/issues?per_page=1"
    end
  end

  describe "fetch_issues_by_states/2" do
    test "returns empty list for empty states" do
      assert {:ok, []} = Client.fetch_issues_by_states([])
    end

    test "fetches issues by state labels" do
      request_fun = fn %{method: :get, url: url} ->
        if url =~ "/timeline" do
          {:ok, %{status: 200, body: []}}
        else
          assert url =~ "labels="
          assert url =~ "sym:todo" or url =~ "sym%3Atodo"

          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 1,
                 "title" => "Task",
                 "body" => nil,
                 "html_url" => "https://github.com/owner/repo/issues/1",
                 "labels" => [%{"name" => "sym:todo"}],
                 "assignee" => nil,
                 "created_at" => "2025-01-01T00:00:00Z",
                 "updated_at" => "2025-01-01T00:00:00Z"
               }
             ]
           }}
        end
      end

      assert {:ok, issues} = Client.fetch_issues_by_states(["todo"], request_fun: request_fun)
      assert length(issues) == 1
      assert hd(issues).id == "1"
      assert hd(issues).state == "todo"
    end

    test "marks paused override without treating it as the issue state" do
      request_fun = fn %{method: :get, url: url} ->
        if url =~ "/timeline" do
          {:ok, %{status: 200, body: []}}
        else
          assert url =~ "sym:todo" or url =~ "sym%3Atodo"

          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 2,
                 "title" => "Paused task",
                 "body" => nil,
                 "html_url" => "https://github.com/owner/repo/issues/2",
                 "labels" => [
                   %{"name" => "sym:paused"},
                   %{"name" => "sym:todo"},
                   %{"name" => "priority:1"}
                 ],
                 "assignee" => nil,
                 "created_at" => "2025-01-01T00:00:00Z",
                 "updated_at" => "2025-01-01T00:00:00Z"
               }
             ]
           }}
        end
      end

      assert {:ok, [issue]} = Client.fetch_issues_by_states(["todo"], request_fun: request_fun)
      assert issue.state == "todo"
      assert issue.paused == true
      assert "sym:paused" in issue.labels
    end
  end

  describe "fetch_issue_states_by_ids/2" do
    test "returns empty list for empty ids" do
      assert {:ok, []} = Client.fetch_issue_states_by_ids([])
    end

    test "fetches individual issues by number" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/repos/owner/repo/issues/42"

        {:ok,
         %{
           status: 200,
           body: %{
             "number" => 42,
             "title" => "Issue",
             "body" => "desc",
             "html_url" => "https://github.com/owner/repo/issues/42",
             "labels" => [%{"name" => "sym:in-progress"}],
             "assignee" => nil,
             "created_at" => "2025-01-01T00:00:00Z",
             "updated_at" => "2025-01-01T00:00:00Z"
           }
         }}
      end

      assert {:ok, [issue]} =
               Client.fetch_issue_states_by_ids(["42"], request_fun: request_fun)

      assert issue.id == "42"
      assert issue.state == "in-progress"
    end

    test "closed issues ignore stale active labels" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/repos/owner/repo/issues/491"

        {:ok,
         %{
           status: 200,
           body: %{
             "number" => 491,
             "state" => "closed",
             "title" => "Merged issue",
             "body" => "desc",
             "html_url" => "https://github.com/owner/repo/issues/491",
             "labels" => [%{"name" => "sym:rework"}],
             "assignee" => nil,
             "created_at" => "2025-01-01T00:00:00Z",
             "updated_at" => "2025-01-01T00:00:00Z"
           }
         }}
      end

      assert {:ok, [issue]} =
               Client.fetch_issue_states_by_ids(["491"], request_fun: request_fun)

      assert issue.id == "491"
      assert issue.state == "Closed"
      assert "sym:rework" in issue.labels
    end

    test "skips 404 issues" do
      request_fun = fn _ ->
        {:ok, %{status: 404}}
      end

      assert {:ok, []} = Client.fetch_issue_states_by_ids(["999"], request_fun: request_fun)
    end
  end

  describe "create_comment/3" do
    test "creates a comment on an issue" do
      request_fun = fn %{method: :post, url: url, body: body} ->
        assert url =~ "/repos/owner/repo/issues/42/comments"
        assert body == %{"body" => "Hello!"}
        {:ok, %{status: 201}}
      end

      assert :ok = Client.create_comment("42", "Hello!", request_fun: request_fun)
    end

    test "returns error on failure" do
      request_fun = fn _ -> {:ok, %{status: 403}} end

      assert {:error, {:github, :http, %{status: 403}}} =
               Client.create_comment("42", "Hello!", request_fun: request_fun)
    end
  end

  describe "fetch_pull_request_head_ref/2" do
    test "returns the PR head branch ref" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/repos/owner/repo/pulls/21"
        {:ok, %{status: 200, body: %{"head" => %{"ref" => "aiur/7"}}}}
      end

      assert {:ok, "aiur/7"} = Client.fetch_pull_request_head_ref(21, request_fun: request_fun)
    end

    test "surfaces a non-200 status as an error" do
      request_fun = fn _ -> {:ok, %{status: 404}} end

      assert {:error, {:github, :http, %{status: 404}}} =
               Client.fetch_pull_request_head_ref(21, request_fun: request_fun)
    end

    test "errors when the head ref is missing from the payload" do
      request_fun = fn _ -> {:ok, %{status: 200, body: %{"head" => %{}}}} end

      assert {:error, :head_ref_missing} =
               Client.fetch_pull_request_head_ref(21, request_fun: request_fun)
    end
  end

  describe "fetch_open_pull_request/2" do
    test "returns the open PR map for an open PR" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/repos/owner/repo/pulls/77"

        {:ok,
         %{
           status: 200,
           body: %{"number" => 77, "state" => "open", "head" => %{"ref" => "feature/login"}}
         }}
      end

      assert {:ok, %{"number" => 77, "head" => %{"ref" => "feature/login"}}} =
               Client.fetch_open_pull_request(77, request_fun: request_fun)
    end

    test "returns nil on 404 (the number is a plain issue, not a PR)" do
      request_fun = fn _ -> {:ok, %{status: 404}} end

      assert {:ok, nil} = Client.fetch_open_pull_request(55, request_fun: request_fun)
    end

    test "returns nil for a closed/merged PR (routes to the legacy path)" do
      request_fun = fn _ ->
        {:ok, %{status: 200, body: %{"number" => 9, "state" => "closed", "head" => %{"ref" => "x"}}}}
      end

      assert {:ok, nil} = Client.fetch_open_pull_request(9, request_fun: request_fun)
    end

    test "surfaces a non-200/404 status as an error" do
      request_fun = fn _ -> {:ok, %{status: 500, body: %{}}} end

      assert {:error, _} = Client.fetch_open_pull_request(77, request_fun: request_fun)
    end
  end

  describe "fetch_open_pull_request_for_branch/2" do
    test "returns the first open PR for a legacy ticket branch" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/repos/owner/repo/pulls?"
        assert url =~ "state=open"

        {:ok, %{status: 200, body: [%{"number" => 49, "head" => %{"ref" => "aiur/35"}}]}}
      end

      assert {:ok, %{"number" => 49}} =
               Client.fetch_open_pull_request_for_branch(35, request_fun: request_fun)
    end

    test "finds an open PR for a readable ticket branch" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/repos/owner/repo/pulls?"

        {:ok,
         %{
           status: 200,
           body: [
             %{"number" => 50, "head" => %{"ref" => "aiur/99-not-this-ticket"}},
             %{"number" => 51, "head" => %{"ref" => "aiur/35-add-new-test-cases"}}
           ]
         }}
      end

      assert {:ok, %{"number" => 51}} =
               Client.fetch_open_pull_request_for_branch(35, request_fun: request_fun)
    end

    test "follows open-PR pages when looking up a readable ticket branch" do
      next_page = "https://api.github.com/repos/owner/repo/pulls?per_page=100&state=open&page=2"

      request_fun = fn %{method: :get, url: url} ->
        cond do
          url == next_page ->
            {:ok,
             %{
               status: 200,
               headers: [],
               body: [%{"number" => 52, "head" => %{"ref" => "aiur/35-add-new-test-cases"}}]
             }}

          url =~ "/repos/owner/repo/pulls?" ->
            {:ok,
             %{
               status: 200,
               headers: [{"link", "<#{next_page}>; rel=\"next\""}],
               body: [%{"number" => 50, "head" => %{"ref" => "feature/not-a-ticket"}}]
             }}
        end
      end

      assert {:ok, %{"number" => 52}} =
               Client.fetch_open_pull_request_for_branch(35, request_fun: request_fun)
    end

    # The saving this change exists for, asserted as a count rather than as a
    # comment: one listing per lookup, where there used to be a `head`-filtered
    # probe in front of it that the listing's own branch filter already covered.
    # `TargetSelection` calls this once per human-review target per poll cycle,
    # so the second request was billing a primary-rate point per target per
    # cycle to answer a question the first one answered.
    test "spends exactly one request when the ticket has an open PR" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      request_fun = fn %{method: :get, url: url} ->
        Agent.update(counter, &(&1 + 1))
        assert url =~ "/repos/owner/repo/pulls?"
        refute url =~ "head="

        {:ok, %{status: 200, body: [%{"number" => 49, "head" => %{"ref" => "aiur/35"}}]}}
      end

      assert {:ok, %{"number" => 49}} =
               Client.fetch_open_pull_request_for_branch(35, request_fun: request_fun)

      assert Agent.get(counter, & &1) == 1
    end

    test "returns nil when the branch has no open PR" do
      request_fun = fn %{method: :get} -> {:ok, %{status: 200, body: []}} end

      assert {:ok, nil} =
               Client.fetch_open_pull_request_for_branch("35", request_fun: request_fun)
    end

    # #2298 item 1: the busiest REST call site routes through `ResourceStore`
    # under the `:branch_pull_request` key, so a second cycle on an unchanged
    # branch revalidates with `If-None-Match` instead of paying full price for
    # the open-pull-request listing again. Asserted on the request map itself
    # (the validator is what the transport turns into the header), then on the
    # `304` being served back as the held pull request.
    test "a second cycle on an unchanged branch issues a conditional request" do
      parent = self()
      etag = ~s("open-pulls-v1")

      request_fun = fn request ->
        case Map.get(request, :etag) do
          nil ->
            send(parent, :unconditional)
            {:ok, %{status: 200, headers: [{"etag", etag}], body: [%{"number" => 49, "head" => %{"ref" => "aiur/35"}}]}}

          ^etag ->
            send(parent, :conditional)
            {:ok, %{status: 304, headers: [{"etag", etag}]}}

          other ->
            flunk("unexpected If-None-Match validator #{inspect(other)}")
        end
      end

      assert {:ok, %{"number" => 49}} =
               Client.fetch_open_pull_request_for_branch(35, request_fun: request_fun)

      assert_receive :unconditional

      assert {:ok, %{"number" => 49}} =
               Client.fetch_open_pull_request_for_branch(35, request_fun: request_fun)

      assert_receive :conditional
    end

    # #2298 structural half (rework B5): the call site stamps the declared
    # `caller:` onto the request it builds. That stamping — not `Quota` reading
    # a field it always read — is the changed line the REST-attribution
    # acceptance depends on, so it is asserted on the request map the real
    # `Client` path produces.
    test "the branch pull-request call site stamps a caller on the request" do
      parent = self()

      request_fun = fn request ->
        send(parent, {:request, request})
        {:ok, %{status: 200, headers: [], body: [%{"number" => 49, "head" => %{"ref" => "aiur/35"}}]}}
      end

      assert {:ok, %{"number" => 49}} =
               Client.fetch_open_pull_request_for_branch(35, request_fun: request_fun)

      assert_receive {:request, request}
      assert request.caller == "open_pull_request_for_branch"
      assert request.url =~ "/pulls?"
    end
  end

  describe "fetch_open_pull_requests_for_branch/2" do
    test "returns every open PR for a ticket's branches, across pages" do
      next_page = "https://api.github.com/repos/owner/repo/pulls?per_page=100&state=open&page=2"

      request_fun = fn %{method: :get, url: url} ->
        cond do
          url == next_page ->
            {:ok,
             %{
               status: 200,
               headers: [],
               body: [%{"number" => 52, "head" => %{"ref" => "aiur/35-add-new-test-cases"}}]
             }}

          url =~ "/repos/owner/repo/pulls?" ->
            {:ok,
             %{
               status: 200,
               headers: [{"link", "<#{next_page}>; rel=\"next\""}],
               body: [
                 %{"number" => 50, "head" => %{"ref" => "feature/not-a-ticket"}},
                 %{"number" => 51, "head" => %{"ref" => "aiur/35-parallel-branch"}}
               ]
             }}
        end
      end

      assert {:ok, pull_requests} =
               Client.fetch_open_pull_requests_for_branch(35, request_fun: request_fun)

      assert Enum.map(pull_requests, &Map.get(&1, "number")) == [51, 52]
    end

    test "returns an empty list when the ticket has no open PR" do
      request_fun = fn %{method: :get} -> {:ok, %{status: 200, body: []}} end

      assert {:ok, []} =
               Client.fetch_open_pull_requests_for_branch("35", request_fun: request_fun)
    end
  end

  describe "fetch_commit_ci_status/2" do
    test "fetches both latest check runs and legacy commit statuses for the head SHA" do
      request_fun = fn %{method: :get, url: url} ->
        cond do
          url =~ "/commits/head-sha/check-runs?filter=latest&per_page=100" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "check_runs" => [
                   %{"name" => "lint", "status" => "completed", "conclusion" => "success"}
                 ]
               }
             }}

          url =~ "/commits/head-sha/status" ->
            {:ok, %{status: 200, body: %{"state" => "success", "statuses" => []}}}
        end
      end

      assert {:ok,
              %{
                check_runs: [%{"name" => "lint"}],
                commit_status: %{"state" => "success"}
              }} = Client.fetch_commit_ci_status("head-sha", request_fun: request_fun)
    end

    test "surfaces a check-run API error without fetching stale success data" do
      request_fun = fn %{method: :get} -> {:ok, %{status: 502, body: %{}}} end

      assert {:error, {:github, :http, %{status: 502}}} =
               Client.fetch_commit_ci_status("head-sha", request_fun: request_fun)
    end
  end

  describe "fetch_classified_pr_review_comments/2" do
    test "labels CODEOWNER review comments authoritative" do
      repo_root = codeowners_repo!("* @owner")

      request_fun = fn %{method: :get, url: url} ->
        cond do
          url =~ "/repos/owner/repo/pulls/7/files" ->
            {:ok, %{status: 200, body: [%{"filename" => "lib/app.ex"}]}}

          url =~ "/repos/owner/repo/pulls/7/comments" ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{"user" => %{"login" => "owner"}, "body" => "Fix this"},
                 %{"user" => %{"login" => "guest"}, "body" => "Maybe fix this"}
               ]
             }}
        end
      end

      assert {:ok, [owner_comment, guest_comment]} =
               Client.fetch_classified_pr_review_comments("7",
                 request_fun: request_fun,
                 repo_root: repo_root
               )

      assert owner_comment.authoritative
      assert owner_comment.authority_reason =~ "CODEOWNER via @owner"
      refute guest_comment.authoritative
      assert guest_comment.authority_reason == "Author is not a CODEOWNER for the relevant paths."

      File.rm_rf!(repo_root)
    end

    test "fails closed on comments when CODEOWNERS is missing" do
      repo_root = Aiur.TestSupport.tmp_root!("aiur-github-client-test")

      File.mkdir_p!(repo_root)

      request_fun = fn %{method: :get, url: url} ->
        cond do
          url =~ "/repos/owner/repo/pulls/8/files" ->
            {:ok, %{status: 200, body: [%{"filename" => "lib/app.ex"}]}}

          url =~ "/repos/owner/repo/pulls/8/comments" ->
            {:ok, %{status: 200, body: [%{"user" => %{"login" => "guest"}, "body" => "Fix this"}]}}
        end
      end

      assert {:ok, [comment]} =
               Client.fetch_classified_pr_review_comments(8,
                 request_fun: request_fun,
                 repo_root: repo_root
               )

      # Prove we really are on the degraded path and not failing for some other
      # reason: there is no CODEOWNERS file under this repo root.
      refute comment.codeowners.codeowners_present

      # SECURITY INVARIANT — this used to be a "compatibility fallback" that made
      # EVERY commenter authoritative whenever CODEOWNERS was missing. On a
      # public repo with issues enabled that meant a drive-by comment from any
      # outsider was handed to the agent as a trusted instruction. Degraded-mode
      # trust now has exactly one owner, `Aiur.GitHub.CodeOwners`, which trusts
      # only `bot_account` + `trusted_accounts` (falling back to the repo owner).
      # `guest` is none of those, so the answer is no.
      #
      # This harness configures no trust source, so the assertion is the
      # fail-closed default rather than the positive case. The positive case —
      # an explicitly configured trusted account IS authoritative in degraded
      # mode — is covered in `test/aiur/codeowners_test.exs`, which can inject a
      # `:trust_server`; this client path resolves the trust server itself and
      # has no seam to inject one.
      refute comment.authoritative

      assert comment.authority_reason ==
               "No CODEOWNERS rules found; only explicitly configured trusted accounts are authoritative."

      File.rm_rf!(repo_root)
    end

    test "abstains when a team-backed CODEOWNERS lookup is quota-held" do
      repo_root = codeowners_repo!("* @acme/platform")

      request_fun = fn %{method: :get, url: url} ->
        cond do
          url =~ "/repos/owner/repo/pulls/9/files" ->
            {:ok, %{status: 200, body: [%{"filename" => "lib/app.ex"}]}}

          url =~ "/repos/owner/repo/pulls/9/comments" ->
            {:ok, %{status: 200, body: [%{"user" => %{"login" => "owner"}, "body" => "Fix this"}]}}

          url =~ "/orgs/acme/teams/platform/members" ->
            {:ok, %{status: 429, body: %{}}}
        end
      end

      assert {:error, :quota_hold} =
               Client.fetch_classified_pr_review_comments(9,
                 request_fun: request_fun,
                 repo_root: repo_root
               )

      File.rm_rf!(repo_root)
    end
  end

  describe "fetch_unaddressed_pr_review_thread_comments/2" do
    test "returns latest trusted comments from unresolved threads only" do
      repo_root = codeowners_repo!("src/owned.ts @owner\n")

      request_fun = fn
        %{method: :post, url: "https://api.github.com/graphql", body: body} ->
          assert body["query"] =~ "reviewThreads"
          assert body["variables"]["owner"] == "owner"
          assert body["variables"]["repo"] == "repo"
          assert body["variables"]["number"] == 61

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "repository" => %{
                   "pullRequest" => %{
                     "reviewThreads" => %{
                       "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                       "nodes" => [
                         %{
                           "id" => "PRRT_first",
                           "isResolved" => false,
                           "path" => "src/owned.ts",
                           "line" => 10,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(101, "owner", "please fix this")
                             ]
                           }
                         },
                         %{
                           "id" => "PRRT_resolved",
                           "isResolved" => true,
                           "path" => "src/owned.ts",
                           "line" => 11,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(102, "owner", "resolved already")
                             ]
                           }
                         },
                         %{
                           "id" => "PRRT_answered",
                           "isResolved" => false,
                           "path" => "src/owned.ts",
                           "line" => 12,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(103, "owner", "agent answered this"),
                               review_thread_comment(104, "aiur-bot", "addressed")
                             ]
                           }
                         },
                         %{
                           "id" => "PRRT_untrusted",
                           "isResolved" => false,
                           "path" => "src/owned.ts",
                           "line" => 13,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(105, "guest", "not trusted")
                             ]
                           }
                         },
                         %{
                           "id" => "PRRT_followup",
                           "isResolved" => false,
                           "path" => "src/owned.ts",
                           "line" => 14,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(106, "owner", "old request"),
                               review_thread_comment(107, "owner", "reviewer follow-up")
                             ]
                           }
                         },
                         %{
                           "id" => "PRRT_no_code_changes",
                           "isResolved" => false,
                           "path" => "src/owned.ts",
                           "line" => 15,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(
                                 108,
                                 "owner",
                                 "wake test, no code changes needed"
                               )
                             ]
                           }
                         }
                       ]
                     }
                   }
                 }
               }
             }
           }}
      end

      assert {:ok, comments} =
               Client.fetch_unaddressed_pr_review_thread_comments(61,
                 request_fun: request_fun,
                 repo_root: repo_root,
                 agent_logins: ["aiur-bot"]
               )

      assert Enum.map(comments, & &1["id"]) == [101, 104, 107, 108]

      assert Enum.map(comments, & &1["review_thread_id"]) == [
               "PRRT_first",
               "PRRT_answered",
               "PRRT_followup",
               "PRRT_no_code_changes"
             ]

      assert Enum.map(comments, & &1["body"]) == [
               "please fix this",
               "addressed",
               "reviewer follow-up",
               "wake test, no code changes needed"
             ]

      assert Enum.all?(comments, & &1.authoritative)
      assert Enum.find(comments, &(&1["review_thread_id"] == "PRRT_answered"))["review_thread_resolution_required"]

      File.rm_rf!(repo_root)
    end
  end

  describe "reply_to_review_thread/3" do
    test "posts a review thread reply and verifies it is the latest bot-authored comment" do
      request_fun = fn
        %{method: :post, url: "https://api.github.com/graphql", body: body} ->
          cond do
            body["query"] =~ "addPullRequestReviewThreadReply" ->
              assert body["variables"] == %{
                       "threadId" => "PRRT_verified",
                       "body" => "Verified this is already fixed."
                     }

              {:ok,
               %{
                 status: 200,
                 body: %{
                   "data" => %{
                     "addPullRequestReviewThreadReply" => %{
                       "comment" => review_thread_comment(202, "aiur-bot", "Verified this is already fixed.")
                     }
                   }
                 }
               }}

            body["query"] =~ "query AiurReviewThread" ->
              assert body["variables"] == %{"id" => "PRRT_verified"}

              review_thread_node_response("PRRT_verified", [
                review_thread_comment(201, "owner", "please verify"),
                review_thread_comment(202, "aiur-bot", "Verified this is already fixed.")
              ])
          end
      end

      assert {:ok, result} =
               Client.reply_to_review_thread("PRRT_verified", "Verified this is already fixed.",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 retry_delay_ms: 0
               )

      assert result.verified
      assert result.review_thread_id == "PRRT_verified"
      assert get_in(result.verification, ["latest_comment", "user", "login"]) == "aiur-bot"
    end

    test "preserves GraphQL errors from the reply mutation" do
      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        assert body["query"] =~ "addPullRequestReviewThreadReply"

        {:ok,
         %{
           status: 200,
           body: %{"errors" => [%{"message" => "Could not resolve to a node"}]}
         }}
      end

      assert {:error, {:github_graphql_errors, [%{"message" => "Could not resolve to a node"}]}} =
               Client.reply_to_review_thread("PRRT_missing", "reply",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 retry_delay_ms: 0
               )
    end

    test "retries verification without posting duplicate replies" do
      {:ok, counts} = Agent.start_link(fn -> %{mutation: 0, query: 0} end)

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "addPullRequestReviewThreadReply" ->
            Agent.update(counts, &Map.update!(&1, :mutation, fn count -> count + 1 end))

            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "addPullRequestReviewThreadReply" => %{
                     "comment" => review_thread_comment(302, "aiur-bot", "Fixed on this branch.")
                   }
                 }
               }
             }}

          body["query"] =~ "query AiurReviewThread" ->
            query_count =
              Agent.get_and_update(counts, fn state ->
                next = state.query + 1
                {next, %{state | query: next}}
              end)

            comments =
              if query_count == 1 do
                [review_thread_comment(301, "owner", "still latest")]
              else
                [
                  review_thread_comment(301, "owner", "still latest"),
                  review_thread_comment(302, "aiur-bot", "Fixed on this branch.")
                ]
              end

            review_thread_node_response("PRRT_retry", comments)
        end
      end

      assert {:ok, %{attempt: 2}} =
               Client.reply_to_review_thread("PRRT_retry", "Fixed on this branch.",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 attempts: 2,
                 retry_delay_ms: 0
               )

      assert Agent.get(counts, & &1) == %{mutation: 1, query: 2}
    end

    test "falls back to the authenticated viewer login when no daemon identity is configured" do
      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "addPullRequestReviewThreadReply" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "addPullRequestReviewThreadReply" => %{
                     "comment" => review_thread_comment(402, "its-everdred", "Verified by body.")
                   }
                 }
               }
             }}

          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_viewer", [
              review_thread_comment(401, "its-everdred", "please verify"),
              review_thread_comment(402, "its-everdred", "Verified by body.")
            ])

          body["query"] =~ "query AiurViewerLogin" ->
            {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "its-everdred"}}}}}
        end
      end

      assert {:ok, result} =
               Client.reply_to_review_thread("PRRT_viewer", "Verified by body.",
                 request_fun: request_fun,
                 retry_delay_ms: 0
               )

      assert result.verified
      assert get_in(result.verification, ["latest_comment", "user", "login"]) == "its-everdred"
      assert get_in(result.verification, ["latest_comment", "body"]) == "Verified by body."
    end

    test "fails verification when the reviewer remains latest across all retries" do
      {:ok, counts} = Agent.start_link(fn -> %{mutation: 0, query: 0} end)

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "addPullRequestReviewThreadReply" ->
            Agent.update(counts, &Map.update!(&1, :mutation, fn count -> count + 1 end))

            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "addPullRequestReviewThreadReply" => %{
                     "comment" => review_thread_comment(502, "aiur-bot", "Fixed on this branch.")
                   }
                 }
               }
             }}

          body["query"] =~ "query AiurReviewThread" ->
            Agent.update(counts, &Map.update!(&1, :query, fn count -> count + 1 end))

            review_thread_node_response("PRRT_stale", [
              review_thread_comment(501, "owner", "still latest")
            ])
        end
      end

      assert {:error,
              {:review_thread_reply_not_verified,
               %{
                 attempts: 3,
                 review_thread_id: "PRRT_stale",
                 reason: {:review_thread_latest_comment_author_mismatch, %{actual: "owner", expected: "aiur-bot"}}
               }}} =
               Client.reply_to_review_thread("PRRT_stale", "Fixed on this branch.",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 attempts: 3,
                 retry_delay_ms: 0
               )

      assert Agent.get(counts, & &1) == %{mutation: 1, query: 3}
    end
  end

  describe "resolve_review_thread/2" do
    test "resolves a review thread with the GraphQL resolveReviewThread mutation" do
      repo_root = codeowners_repo!("* @owner\n")

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_done", [
              review_thread_comment(701, "owner", "please verify"),
              review_thread_comment(702, "aiur-bot", "Done, no further changes.")
            ])

          body["query"] =~ "resolveReviewThread" ->
            assert body["variables"] == %{"threadId" => "PRRT_done"}

            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "resolveReviewThread" => %{
                     "thread" => %{
                       "id" => "PRRT_done",
                       "isResolved" => true
                     }
                   }
                 }
               }
             }}
        end
      end

      assert {:ok, result} =
               Client.resolve_review_thread("PRRT_done",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes.",
                 repo_root: repo_root
               )

      assert result.resolved
      assert result.review_thread_id == "PRRT_done"
      assert get_in(result.verification, ["latest_comment", "user", "login"]) == "aiur-bot"

      File.rm_rf!(repo_root)
    end

    test "fails after resolving when a reviewer follow-up becomes latest in the resolve window" do
      repo_root = codeowners_repo!("* @owner\n")
      {:ok, query_count} = Agent.start_link(fn -> 0 end)
      {:ok, unresolve_count} = Agent.start_link(fn -> 0 end)

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            case Agent.get_and_update(query_count, &{&1, &1 + 1}) do
              0 ->
                review_thread_node_response("PRRT_raced", [
                  review_thread_comment(711, "owner", "please verify"),
                  review_thread_comment(712, "aiur-bot", "Done, no further changes.")
                ])

              1 ->
                review_thread_node_response(
                  "PRRT_raced",
                  [
                    review_thread_comment(711, "owner", "please verify"),
                    review_thread_comment(712, "aiur-bot", "Done, no further changes."),
                    review_thread_comment(713, "owner", "Actually, please also fix this.")
                  ],
                  %{"isResolved" => true}
                )
            end

          body["query"] =~ "unresolveReviewThread" ->
            Agent.update(unresolve_count, &(&1 + 1))
            assert body["variables"] == %{"threadId" => "PRRT_raced"}

            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "unresolveReviewThread" => %{
                     "thread" => %{
                       "id" => "PRRT_raced",
                       "isResolved" => false
                     }
                   }
                 }
               }
             }}

          body["query"] =~ "resolveReviewThread" ->
            assert body["variables"] == %{"threadId" => "PRRT_raced"}

            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "resolveReviewThread" => %{
                     "thread" => %{
                       "id" => "PRRT_raced",
                       "isResolved" => true
                     }
                   }
                 }
               }
             }}
        end
      end

      assert {:error,
              {:review_thread_resolution_precondition_failed,
               %{
                 reason: :post_resolve_latest_comment_author_mismatch,
                 review_thread_id: "PRRT_raced",
                 latest_comment: %{"body" => "Actually, please also fix this."},
                 unresolved_after_post_resolve_mismatch: %{
                   review_thread_id: "PRRT_raced",
                   mutation_response: %{
                     "data" => %{
                       "unresolveReviewThread" => %{
                         "thread" => %{
                           "id" => "PRRT_raced",
                           "isResolved" => false
                         }
                       }
                     }
                   }
                 }
               }}} =
               Client.resolve_review_thread("PRRT_raced",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes.",
                 repo_root: repo_root
               )

      assert Agent.get(query_count, & &1) == 2
      assert Agent.get(unresolve_count, & &1) == 1

      File.rm_rf!(repo_root)
    end

    test "classifies resolve permission failures with required token guidance" do
      repo_root = codeowners_repo!("* @owner\n")

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_denied", [
              review_thread_comment(801, "owner", "please verify"),
              review_thread_comment(802, "aiur-bot", "Done, no further changes.")
            ])

          body["query"] =~ "resolveReviewThread" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "errors" => [
                   %{"message" => "Resource not accessible by personal access token", "type" => "FORBIDDEN"}
                 ]
               }
             }}
        end
      end

      assert {:error,
              {:review_thread_resolution_not_permitted,
               %{
                 review_thread_id: "PRRT_denied",
                 errors: [%{"message" => "Resource not accessible by personal access token"}],
                 required_permission: required_permission
               }}} =
               Client.resolve_review_thread("PRRT_denied",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes.",
                 repo_root: repo_root
               )

      assert required_permission =~ "Pull requests: Read and write"

      File.rm_rf!(repo_root)
    end

    test "does not classify unrelated GraphQL errors as token permission failures" do
      repo_root = codeowners_repo!("* @owner\n")

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_error", [
              review_thread_comment(811, "owner", "please verify"),
              review_thread_comment(812, "aiur-bot", "Done, no further changes.")
            ])

          body["query"] =~ "resolveReviewThread" ->
            {:ok,
             %{
               status: 200,
               body: %{"errors" => [%{"message" => "not permitted on an already resolved thread"}]}
             }}
        end
      end

      assert {:error, {:github_graphql_errors, [%{"message" => "not permitted on an already resolved thread"}]}} =
               Client.resolve_review_thread("PRRT_error",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes.",
                 repo_root: repo_root
               )

      File.rm_rf!(repo_root)
    end

    test "fails when the mutation does not report a resolved thread" do
      repo_root = codeowners_repo!("* @owner\n")

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_still_open", [
              review_thread_comment(901, "owner", "please verify"),
              review_thread_comment(902, "aiur-bot", "Done, no further changes.")
            ])

          body["query"] =~ "resolveReviewThread" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "resolveReviewThread" => %{
                     "thread" => %{
                       "id" => "PRRT_still_open",
                       "isResolved" => false
                     }
                   }
                 }
               }
             }}
        end
      end

      assert {:error, {:review_thread_not_resolved, %{review_thread_id: "PRRT_still_open"}}} =
               Client.resolve_review_thread("PRRT_still_open",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes.",
                 repo_root: repo_root
               )

      File.rm_rf!(repo_root)
    end

    test "refuses to resolve when the terminal reply is no longer the latest comment" do
      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_followup", [
              review_thread_comment(1001, "owner", "please verify"),
              review_thread_comment(1002, "aiur-bot", "Done, no further changes."),
              review_thread_comment(1003, "owner", "Actually, please also fix this.")
            ])

          body["query"] =~ "resolveReviewThread" ->
            flunk("resolveReviewThread must not be called when a reviewer follow-up is latest")
        end
      end

      assert {:error,
              {:review_thread_resolution_precondition_failed,
               %{
                 reason: :latest_comment_author_mismatch,
                 review_thread_id: "PRRT_followup"
               }}} =
               Client.resolve_review_thread("PRRT_followup",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes."
               )
    end

    test "refuses to resolve when the reviewer is outside the CODEOWNERS trust boundary" do
      repo_root = codeowners_repo!("* @owner\n")

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_nonowner", [
              review_thread_comment(1101, "guest", "please verify"),
              review_thread_comment(1102, "aiur-bot", "Done, no further changes.")
            ])

          body["query"] =~ "resolveReviewThread" ->
            flunk("resolveReviewThread must not be called for non-authoritative reviewer threads")
        end
      end

      assert {:error, {:review_thread_resolution_not_authorized, %{review_thread_id: "PRRT_nonowner", path: "src/lib/aiur/github/client.ex"}}} =
               Client.resolve_review_thread("PRRT_nonowner",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes.",
                 repo_root: repo_root
               )

      File.rm_rf!(repo_root)
    end
  end

  describe "fetch_classified_issue_comments/2" do
    test "uses repo-wide CODEOWNERS for issue comments without PR paths" do
      repo_root = codeowners_repo!("docs/ @docs-owner\n")

      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/repos/owner/repo/issues/42/comments"

        {:ok,
         %{
           status: 200,
           body: [
             %{"user" => %{"login" => "docs-owner"}, "body" => "Directive"},
             %{"user" => %{"login" => "guest"}, "body" => "Suggestion"}
           ]
         }}
      end

      assert {:ok, [owner_comment, guest_comment]} =
               Client.fetch_classified_issue_comments("42",
                 request_fun: request_fun,
                 repo_root: repo_root
               )

      assert owner_comment.authoritative
      refute guest_comment.authoritative

      File.rm_rf!(repo_root)
    end

    test "abstains when a team-backed CODEOWNERS lookup is quota-held" do
      repo_root = codeowners_repo!("* @acme/platform")

      request_fun = fn %{method: :get, url: url} ->
        cond do
          url =~ "/orgs/acme/teams/platform/members" ->
            {:ok, %{status: 429, body: %{}}}

          url =~ "/repos/owner/repo/issues/43/comments" ->
            {:ok, %{status: 200, body: [%{"user" => %{"login" => "owner"}, "body" => "Directive"}]}}
        end
      end

      assert {:error, :quota_hold} =
               Client.fetch_classified_issue_comments("43",
                 request_fun: request_fun,
                 repo_root: repo_root
               )

      File.rm_rf!(repo_root)
    end
  end

  describe "update_issue_state/3" do
    test "swaps labels and closes terminal issues" do
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn req ->
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          # GET issue
          {:get, 0} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "labels" => [%{"name" => "sym:todo"}, %{"name" => "other"}]
               }
             }}

          # DELETE old label
          {:delete, 1} ->
            assert req.url =~ "sym:todo" or req.url =~ "sym%3Atodo"
            {:ok, %{status: 200}}

          # POST new label
          {:post, 2} ->
            assert req.body == %{"labels" => ["sym:done"]}
            {:ok, %{status: 200}}

          # PATCH close
          {:patch, 3} ->
            assert req.body == %{"state" => "closed"}
            {:ok, %{status: 200}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert :ok = Client.update_issue_state("42", "Done", request_fun: request_fun)
    end

    test "state swaps preserve paused and watch marker labels" do
      test_pid = self()
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn req ->
        send(test_pid, {:github_request, req})
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          {:get, 0} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [
                   %{"name" => "sym:paused"},
                   %{"name" => "sym:todo"},
                   %{"name" => "sym:watch"}
                 ]
               }
             }}

          {:delete, 1} ->
            assert req.url =~ "sym:todo" or req.url =~ "sym%3Atodo"
            {:ok, %{status: 200}}

          {:get, 2} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:paused"}, %{"name" => "sym:watch"}]
               }
             }}

          {:post, 3} ->
            assert req.body == %{"labels" => ["sym:rework"]}
            {:ok, %{status: 200}}
        end
      end

      assert :ok = Client.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:github_request, %{method: :get}}
      assert_receive {:github_request, %{method: :delete, url: deleted_url}}
      assert_receive {:github_request, %{method: :get}}
      assert_receive {:github_request, %{method: :post, body: %{"labels" => ["sym:rework"]}}}
      refute deleted_url =~ "sym:paused"
      refute deleted_url =~ "sym:watch"
      refute_receive {:github_request, %{method: :delete}}, 100
    end

    test "human-review readiness requires unresolved authenticated-viewer replies to be resolved" do
      repo_root = codeowners_repo!("* @its-everdred\n")
      test_pid = self()

      request_fun = fn req ->
        send(test_pid, {:github_request, req})

        cond do
          # No standing approval on this PR, so the #1756 approval override
          # does not apply and the unresolved thread still blocks.
          req.method == :get and req.url =~ "/pulls/77/reviews" ->
            {:ok, %{status: 200, body: []}}

          req.method == :get and req.url =~ "/pulls?" ->
            {:ok, %{status: 200, body: [%{"number" => 77, "head" => %{"ref" => "aiur/42"}}]}}

          req.method == :post and req.body["query"] =~ "query AiurViewerLogin" ->
            {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "its-everdred"}}}}}

          req.method == :post and req.body["query"] =~ "AiurUnaddressedReviewThreads" ->
            review_threads_page_response([
              %{
                "id" => "PRRT_self_reply",
                "isResolved" => false,
                "path" => "src/lib/aiur/github/client.ex",
                "line" => 12,
                "comments" => %{
                  "nodes" => [
                    review_thread_comment(601, "its-everdred", "Verified on this branch.")
                  ]
                }
              }
            ])
        end
      end

      assert {:error, {:unverified_review_threads, %{count: 1, pr_number: 77, review_thread_ids: ["PRRT_self_reply"]}}} =
               Client.verify_human_review_ready("42",
                 request_fun: request_fun,
                 repo_root: repo_root,
                 bot_account: nil
               )

      assert_receive {:github_request, %{method: :get, url: pulls_url}}
      assert pulls_url =~ "/pulls?"
      assert_receive {:github_request, %{method: :post, body: %{"query" => viewer_query}}}
      assert viewer_query =~ "AiurViewerLogin"
      assert_receive {:github_request, %{method: :post, body: %{"query" => threads_query}}}
      assert threads_query =~ "AiurUnaddressedReviewThreads"

      File.rm_rf!(repo_root)
    end

    test "human-review readiness allows authenticated-viewer replies when the thread is resolved" do
      repo_root = codeowners_repo!("* @its-everdred\n")

      request_fun = fn req ->
        cond do
          req.method == :get and req.url =~ "/pulls?" ->
            {:ok, %{status: 200, body: [%{"number" => 77, "head" => %{"ref" => "aiur/42"}}]}}

          req.method == :post and req.body["query"] =~ "query AiurViewerLogin" ->
            {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "its-everdred"}}}}}

          req.method == :post and req.body["query"] =~ "AiurUnaddressedReviewThreads" ->
            review_threads_page_response([
              %{
                "id" => "PRRT_self_reply",
                "isResolved" => true,
                "path" => "src/lib/aiur/github/client.ex",
                "line" => 12,
                "comments" => %{
                  "nodes" => [
                    review_thread_comment(601, "its-everdred", "Verified on this branch.")
                  ]
                }
              }
            ])
        end
      end

      assert :ok =
               Client.verify_human_review_ready("42",
                 request_fun: request_fun,
                 repo_root: repo_root,
                 bot_account: nil
               )

      File.rm_rf!(repo_root)
    end

    test "refuses human-review while authoritative review threads remain unverified" do
      test_pid = self()

      request_fun = fn req ->
        send(test_pid, {:github_request, req})

        cond do
          req.method == :get and req.url =~ "/issues/42" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:in-progress"}]
               }
             }}

          # No standing approval, so the #1756 approval override does not apply.
          req.method == :get and req.url =~ "/pulls/77/reviews" ->
            {:ok, %{status: 200, body: []}}

          req.method == :get and req.url =~ "/pulls?" ->
            {:ok, %{status: 200, body: [%{"number" => 77, "head" => %{"ref" => "aiur/42"}}]}}

          req.method == :post and req.url == "https://api.github.com/graphql" ->
            review_threads_page_response([
              %{
                "id" => "PRRT_blocking",
                "isResolved" => false,
                "path" => "src/lib/aiur/github/client.ex",
                "line" => 12,
                "comments" => %{
                  "nodes" => [
                    review_thread_comment(401, "its-everdred", "please verify this exact thread")
                  ]
                }
              }
            ])
        end
      end

      assert {:error, {:unverified_review_threads, %{count: 1, pr_number: 77, review_thread_ids: ["PRRT_blocking"]}}} =
               Client.update_issue_state("42", "human-review",
                 request_fun: request_fun,
                 bot_account: "aiur-bot"
               )

      assert_receive {:github_request, %{method: :get}}
      assert_receive {:github_request, %{method: :get, url: pulls_url}}
      assert pulls_url =~ "/repos/owner/repo/pulls?"
      assert pulls_url =~ "state=open"
      # The `head=` probe is gone: the listing's own branch filter already
      # covered every branch spelling it could match, so it was a second billed
      # request per lookup that answered nothing new.
      refute pulls_url =~ "head="
      assert_receive {:github_request, %{method: :post, url: "https://api.github.com/graphql"}}
      refute_receive {:github_request, %{method: :delete}}, 100

      refute_receive {:github_request, %{method: :post, body: %{"labels" => ["sym:human-review"]}}},
                     100
    end

    test "allows human-review when the open PR has no unaddressed review threads" do
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn req ->
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          {:get, 0} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:in-progress"}]
               }
             }}

          {:get, 1} ->
            assert req.url =~ "/pulls?"
            {:ok, %{status: 200, body: [%{"number" => 77, "head" => %{"ref" => "aiur/42"}}]}}

          {:post, 2} ->
            assert req.url == "https://api.github.com/graphql"
            review_threads_page_response([])

          {:delete, 3} ->
            assert req.url =~ "sym:in-progress" or req.url =~ "sym%3Ain-progress"
            {:ok, %{status: 200}}

          {:get, 4} ->
            assert req.url =~ "/issues/42"

            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => []
               }
             }}

          {:post, 5} ->
            assert req.body == %{"labels" => ["sym:human-review"]}
            {:ok, %{status: 200}}
        end
      end

      assert :ok =
               Client.update_issue_state("42", "human-review",
                 request_fun: request_fun,
                 bot_account: "aiur-bot"
               )
    end

    test "closed issues remove stale active labels without adding a new active label" do
      test_pid = self()

      request_fun = fn req ->
        send(test_pid, {:github_request, req})

        case req.method do
          :get ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "closed",
                 "labels" => [
                   %{"name" => "sym:done"},
                   %{"name" => "sym:human-review"},
                   %{"name" => "sym:rework"},
                   %{"name" => "other"}
                 ]
               }
             }}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert :ok = Client.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:github_request, %{method: :get}}
      assert_receive {:github_request, %{method: :delete, url: human_review_url}}
      assert_receive {:github_request, %{method: :delete, url: rework_url}}
      refute human_review_url =~ "sym:done"
      refute rework_url =~ "sym:done"
      refute_receive {:github_request, %{method: :post}}, 100
      refute_receive {:github_request, %{method: :patch}}, 100

      assert human_review_url =~ "sym:human-review" or human_review_url =~ "sym%3Ahuman-review"
      assert rework_url =~ "sym:rework" or rework_url =~ "sym%3Arework"
    end

    test "active label add rechecks issue state after stale label removal" do
      test_pid = self()
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn req ->
        send(test_pid, {:github_request, req})
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          {:get, 0} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:human-review"}]
               }
             }}

          {:delete, 1} ->
            {:ok, %{status: 200}}

          {:get, 2} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "closed",
                 "labels" => [%{"name" => "sym:done"}, %{"name" => "sym:rework"}]
               }
             }}

          {:delete, 3} ->
            {:ok, %{status: 200}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert :ok = Client.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:github_request, %{method: :get}}
      assert_receive {:github_request, %{method: :delete, url: human_review_url}}
      assert_receive {:github_request, %{method: :get}}
      assert_receive {:github_request, %{method: :delete, url: rework_url}}
      refute human_review_url =~ "sym:done"
      refute rework_url =~ "sym:done"
      refute_receive {:github_request, %{method: :post}}, 100
      refute_receive {:github_request, %{method: :patch}}, 100

      assert human_review_url =~ "sym:human-review" or human_review_url =~ "sym%3Ahuman-review"
      assert rework_url =~ "sym:rework" or rework_url =~ "sym%3Arework"
    end

    test "closed issue active-label cleanup reports delete failures" do
      test_pid = self()

      request_fun = fn req ->
        send(test_pid, {:github_request, req})

        case req.method do
          :get ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "closed",
                 "labels" => [%{"name" => "sym:human-review"}]
               }
             }}

          :delete ->
            {:ok, %{status: 500}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert {:error, {:github, :http, %{status: 500}}} =
               Client.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:github_request, %{method: :get}}
      assert_receive {:github_request, %{method: :delete}}
      refute_receive {:github_request, %{method: :post}}, 100
      refute_receive {:github_request, %{method: :patch}}, 100
    end
  end

  describe "classify_error/1 (error taxonomy)" do
    # Operators must be able to tell a DNS/connectivity failure apart from an
    # auth failure to fix flaky GitHub access (#617): a DNS outage and an
    # expired token need different remediation, but both used to flatten into
    # the opaque {:github_api_request, reason} tuple. Each branch below pins a
    # distinct, pattern-matchable classification so callers can route on it.

    test "an :nxdomain transport error classifies as :dns" do
      assert {:github, :dns, detail} =
               Client.classify_error({:error, %Req.TransportError{reason: :nxdomain}})

      assert detail.reason == :nxdomain
    end

    test "a Mint.TransportError :nxdomain also classifies as :dns" do
      # Req wraps Mint, but classification keys off the shared :reason field so
      # either struct surfaces identically.
      assert {:github, :dns, _detail} =
               Client.classify_error({:error, %Mint.TransportError{reason: :nxdomain}})
    end

    test "a :timeout / :closed / :econnrefused transport error classifies as :timeout" do
      for reason <- [:timeout, :closed, :econnrefused] do
        assert {:github, :timeout, %{reason: ^reason}} =
                 Client.classify_error({:error, %Req.TransportError{reason: reason}})
      end
    end

    test "a TLS alert transport error classifies as :tls" do
      assert {:github, :tls, _detail} =
               Client.classify_error({:error, %Req.TransportError{reason: {:tls_alert, {:handshake_failure, "x"}}}})
    end

    test "an HTTP 401 classifies as :auth" do
      assert {:github, :auth, %{status: 401}} =
               Client.classify_error(%{status: 401, headers: [], body: %{}})
    end

    test "an HTTP 403 rate-limit response classifies as :rate_limited" do
      response = %{
        status: 403,
        headers: [{"x-ratelimit-remaining", "0"}, {"retry-after", "42"}, {"x-ratelimit-reset", "1900000000"}],
        body: %{"message" => "API rate limit exceeded"}
      }

      assert {:github, :rate_limited, detail} = Client.classify_error(response)
      assert detail.retry_after == 42
      assert detail.reset_at == "2030-03-17T17:46:40Z"
    end

    test "a plain HTTP 403 (no rate-limit signal) classifies as :http" do
      assert {:github, :http, %{status: 403}} =
               Client.classify_error(%{status: 403, headers: [], body: %{}})
    end

    test "an unmapped 5xx status classifies as :http" do
      assert {:github, :http, %{status: 503}} =
               Client.classify_error(%{status: 503, headers: [], body: %{}})
    end
  end

  describe "transport failures surface the taxonomy (not opaque tuples)" do
    test "fetch_repo_events maps an :nxdomain DNS failure to {:github, :dns, _}" do
      request_fun = fn _ -> {:error, %Req.TransportError{reason: :nxdomain}} end

      assert {:error, {:github, :dns, _detail}} =
               Client.fetch_repo_events(request_fun: request_fun, token: "test-gh-token")
    end

    test "create_comment maps a transport timeout to {:github, :timeout, _}" do
      request_fun = fn _ -> {:error, %Req.TransportError{reason: :timeout}} end

      assert {:error, {:github, :timeout, _detail}} =
               Client.create_comment("42", "hi", request_fun: request_fun)
    end
  end

  describe "Build Order planning graph reads" do
    test "delegates catalog reads to the separate bounded planning adapter" do
      request_fun = fn %{method: :post, body: body} ->
        assert body["query"] =~ "AiurBuildOrderCatalog"

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "repository" => %{
                 "issues" => %{
                   "nodes" => [],
                   "totalCount" => 0,
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end

      assert {:ok, %{candidate: %{entries: []}, calls: 1, pages: 1}} =
               Client.fetch_build_order_catalog(request_fun: request_fun)
    end
  end

  defp codeowners_repo!(content) do
    repo_root = Aiur.TestSupport.tmp_root!("aiur-github-client-test")

    path = Path.join(repo_root, ".github/CODEOWNERS")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    repo_root
  end

  defp review_thread_comment(id, login, body) do
    %{
      "id" => "PRRC_#{id}",
      "databaseId" => id,
      "body" => body,
      "createdAt" => "2026-06-25T04:13:21Z",
      "updatedAt" => "2026-06-25T04:13:21Z",
      "url" => "https://github.test/discussion_r#{id}",
      "author" => %{"login" => login}
    }
  end

  defp review_thread_node_response(thread_id, comments, attrs \\ %{}) do
    {:ok,
     %{
       status: 200,
       body: %{
         "data" => %{
           "node" =>
             Map.merge(
               %{
                 "id" => thread_id,
                 "isResolved" => false,
                 "path" => "src/lib/aiur/github/client.ex",
                 "line" => 12,
                 "comments" => %{"nodes" => comments}
               },
               attrs
             )
         }
       }
     }}
  end

  defp review_threads_page_response(nodes) do
    {:ok,
     %{
       status: 200,
       body: %{
         "data" => %{
           "repository" => %{
             "pullRequest" => %{
               "reviewThreads" => %{
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                 "nodes" => nodes
               }
             }
           }
         }
       }
     }}
  end
end
