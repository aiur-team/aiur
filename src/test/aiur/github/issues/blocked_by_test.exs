defmodule Aiur.GitHub.Issues.BlockedByTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Issues
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Issue
  alias Aiur.Orchestrator.DispatchPolicy

  # A double of `/issues/:n/dependencies/blocked_by` as observed on the reported
  # run: it answers `304` to anything carrying a validator — its ETag tracks the
  # blocked issue, not the blocker state it embeds — and the truth to an
  # unconditional read (#2550, #2552).
  defp stale_validator_endpoint(fresh) do
    fn request ->
      if Map.has_key?(request, :etag) do
        {:ok, %{status: 304, headers: [{"etag", ~s("e1")}]}}
      else
        {:ok, %{status: 200, body: fresh, headers: [{"etag", ~s("e2")}]}}
      end
    end
  end

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

      assert Enum.map(blockers, &Map.delete(&1, :observed_at_ms)) == [
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

    test "a hydrated closed blocker clears the dependency gate (#2545)" do
      request_fun = fn %{method: :get, url: _url} ->
        blockers = [
          %{"number" => 3, "html_url" => "u3", "state" => "closed", "labels" => [%{"name" => "sym:done"}]},
          %{"number" => 7, "html_url" => "u7", "state" => "closed", "labels" => []}
        ]

        {:ok, %{status: 200, body: blockers}}
      end

      issue = %Issue{id: "12", identifier: "12", title: "t", state: "todo"}

      assert {:ok, %Issue{blocked_by: blockers} = hydrated} =
               Issues.hydrate_blocked_by(issue, request_fun: request_fun)

      assert Enum.map(blockers, & &1.state) == ["Closed", "Closed"]

      # The configured terminal set has no "closed" entry — the gate must still
      # let the ticket through, or a closed GitHub blocker strands its blockee.
      refute DispatchPolicy.issue_held_by_dependency?(hydrated, MapSet.new(["done", "cancelled"]))
    end

    # Regression for #2550 / #2552, from the aiur-team/architecture-docs run:
    # eighteen `agent:todo` tickets sat at `dispatch_decline=:dependency` against
    # blockers that had closed hours earlier. `hydrate_blocked_by/1` asks for
    # freshness, but the endpoint's validator tracks the *blocked* issue rather
    # than the blocker objects it embeds, so a conditional read was answered
    # `304` and the store's original body — with the blocker's original labels —
    # was handed to the gate. Only `ResourceStore.forget/1` cleared it.
    #
    # The double below is that endpoint: `304` to anything conditional, the truth
    # to an unconditional read.
    test "a blocker closed since the list was stored clears the gate without an explicit forget (#2550)" do
      ResourceStore.reset()
      on_exit(&ResourceStore.reset/0)

      key = ResourceStore.key_for_repo(:issue_blocked_by, "owner/repo", 24)
      held = [%{"number" => 14, "html_url" => "u14", "state" => "open", "labels" => [%{"name" => "sym:todo"}]}]
      ResourceStore.put_resource(key, held, source: :fetch, etag: ~s("e1"))

      closed = [%{"number" => 14, "html_url" => "u14", "state" => "closed", "labels" => [%{"name" => "sym:done"}], "updated_at" => "2026-09-04T10:00:00Z"}]

      issue = %Issue{id: "24", identifier: "24", title: "t", state: "todo"}

      assert {:ok, %Issue{blocked_by: [blocker]} = hydrated} =
               Issues.hydrate_blocked_by(issue, revalidate: true, request_fun: stale_validator_endpoint(closed))

      assert blocker.state == "Closed"
      refute DispatchPolicy.issue_held_by_dependency?(hydrated, MapSet.new(["done", "cancelled"]))
    end

    test "a dependency edge deleted on GitHub clears the gate without an explicit forget (#2552)" do
      ResourceStore.reset()
      on_exit(&ResourceStore.reset/0)

      key = ResourceStore.key_for_repo(:issue_blocked_by, "owner/repo", 25)
      held = [%{"number" => 14, "html_url" => "u14", "state" => "open", "labels" => [%{"name" => "sym:todo"}]}]
      ResourceStore.put_resource(key, held, source: :fetch, etag: ~s("e1"))

      issue = %Issue{id: "25", identifier: "25", title: "t", state: "todo"}

      assert {:ok, %Issue{blocked_by: []} = hydrated} =
               Issues.hydrate_blocked_by(issue, revalidate: true, request_fun: stale_validator_endpoint([]))

      refute DispatchPolicy.issue_held_by_dependency?(hydrated, MapSet.new(["done", "cancelled"]))
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
end
