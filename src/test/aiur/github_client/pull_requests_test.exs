defmodule Aiur.GitHub.Client.PullRequestsTest do
  use Aiur.TestSupport

  import Aiur.GitHub.ClientTestSupport

  alias Aiur.GitHub.{Client, ResourceStore}

  setup do
    setup_client()
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

    test "revalidates a held pull request with If-None-Match instead of a full read" do
      # #2352 row 5: `Client.fetch_open_pull_request` routes through
      # `ResourceFetch` under the `:pull_request` key, so a second read of the
      # same PR number sends If-None-Match and GitHub's 304 is answered without
      # a full-price re-read. The acceptance is that the read *carries* the
      # validator, not merely that a 304 is handled.
      key = ResourceStore.key_for_repo(:pull_request, "owner/repo", 4242)
      on_exit(fn -> ResourceStore.drop_data(key) end)

      parent = self()

      first = fn %{method: :get, url: url} ->
        assert url =~ "/pulls/4242"

        {:ok,
         %{
           status: 200,
           body: %{"number" => 4242, "state" => "open", "head" => %{"ref" => "x"}, "updated_at" => "2026-01-01T00:00:00Z"},
           headers: [{"etag", ~s("v1")}]
         }}
      end

      second = fn request ->
        send(parent, {:requested, request})
        {:ok, %{status: 304, headers: [{"etag", ~s("v1")}]}}
      end

      assert {:ok, %{"number" => 4242}} = Client.fetch_open_pull_request(4242, request_fun: first)
      assert {:ok, %{"number" => 4242}} = Client.fetch_open_pull_request(4242, request_fun: second)

      assert_receive {:requested, request}, 1000
      assert request.etag == ~s("v1")
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

      assert_receive :unconditional, 1000

      assert {:ok, %{"number" => 49}} =
               Client.fetch_open_pull_request_for_branch(35, request_fun: request_fun)

      assert_receive :conditional, 1000
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

      assert_receive {:request, request}, 1000
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
    test "strictly revalidates both CI endpoints and reuses only the 304-confirmed bodies" do
      check_key = ResourceStore.key(:commit_ci_check_runs, "owner", "repo", "etag-sha:1")
      status_key = ResourceStore.key(:commit_ci_status, "owner", "repo", "etag-sha")

      on_exit(fn ->
        ResourceStore.drop_data(check_key)
        ResourceStore.drop_data(status_key)
      end)

      parent = self()

      first = fn %{url: url} ->
        cond do
          String.ends_with?(url, "/check-runs?filter=latest&per_page=100") ->
            {:ok, %{status: 200, body: %{"check_runs" => [%{"name" => "lint", "status" => "completed", "conclusion" => "success"}]}, headers: [{"etag", ~s("runs-v1")}]}}

          String.ends_with?(url, "/status") ->
            {:ok, %{status: 200, body: %{"state" => "success", "statuses" => []}, headers: [{"etag", ~s("status-v1")}]}}
        end
      end

      second = fn request ->
        send(parent, {:conditional_request, request.url, Map.get(request, :etag)})
        {:ok, %{status: 304, headers: [{"etag", Map.get(request, :etag)}]}}
      end

      assert {:ok, expected} = Client.fetch_commit_ci_status("etag-sha", request_fun: first)
      assert {:ok, ^expected} = Client.fetch_commit_ci_status("etag-sha", request_fun: second)
      assert_received {:conditional_request, runs_url, ~s("runs-v1")}
      assert runs_url =~ "/check-runs?"
      assert_received {:conditional_request, status_url, ~s("status-v1")}
      assert String.ends_with?(status_url, "/status")
    end

    test "revalidates every check-run page instead of trusting page one's ETag for the whole list" do
      first_page_key = ResourceStore.key(:commit_ci_check_runs, "owner", "repo", "paged-sha:1")
      second_page_key = ResourceStore.key(:commit_ci_check_runs, "owner", "repo", "paged-sha:2")
      status_key = ResourceStore.key(:commit_ci_status, "owner", "repo", "paged-sha")
      keys = [first_page_key, second_page_key, status_key]
      on_exit(fn -> Enum.each(keys, &ResourceStore.drop_data/1) end)

      page_two = "https://api.github.com/repos/owner/repo/commits/paged-sha/check-runs?filter=latest&per_page=100&page=2"
      parent = self()

      first = fn %{url: url} ->
        cond do
          url =~ "page=2" ->
            {:ok, %{status: 200, body: %{"check_runs" => [%{"name" => "second", "status" => "completed"}]}, headers: [{"etag", ~s("runs-p2")}]}}

          url =~ "/check-runs?" ->
            {:ok, %{status: 200, body: %{"check_runs" => [%{"name" => "first", "status" => "completed"}]}, headers: [{"etag", ~s("runs-p1")}, {"link", "<#{page_two}>; rel=\"next\""}]}}

          true ->
            {:ok, %{status: 200, body: %{"state" => "success", "statuses" => []}, headers: [{"etag", ~s("status-v1")}]}}
        end
      end

      second = fn request ->
        send(parent, {:revalidated_page, request.url, Map.get(request, :etag)})
        {:ok, %{status: 304, headers: [{"etag", Map.get(request, :etag)}]}}
      end

      assert {:ok, %{check_runs: [%{"name" => "first"}, %{"name" => "second"}]}} =
               Client.fetch_commit_ci_status("paged-sha", request_fun: first)

      assert {:ok, %{check_runs: [%{"name" => "first"}, %{"name" => "second"}]}} =
               Client.fetch_commit_ci_status("paged-sha", request_fun: second)

      assert_received {:revalidated_page, first_url, ~s("runs-p1")}
      assert first_url =~ "/check-runs?"
      assert_received {:revalidated_page, ^page_two, ~s("runs-p2")}
      assert_received {:revalidated_page, status_url, ~s("status-v1")}
      assert String.ends_with?(status_url, "/status")
    end

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
end
