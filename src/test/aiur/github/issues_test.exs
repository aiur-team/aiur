defmodule Aiur.GitHub.IssuesTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{DependencyCache, Issues}
  alias Aiur.Orchestrator.DispatchPolicy

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

    DependencyCache.clear({"owner", "repo"})

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

          {:ok, %{status: 200, body: body}}
        else
          {:ok, %{status: 200, body: []}}
        end
      end

      assert {:ok, [issue]} = Issues.fetch_issues_by_states(["todo"], request_fun: request_fun)
      assert issue.id == "7"
      assert issue.state == "todo"
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
          next = ~s(<https://api.github.com/repos/owner/repo/issues?labels=sym%3Aci-wait&state=open&per_page=100&page=2>; rel="next")
          {:ok, %{status: 200, headers: [{"link", next}], body: [issue.(100)]}}
        end
      end

      assert {:ok, issues} = Issues.fetch_issues_by_states(["ci-wait"], request_fun: request_fun)
      assert Enum.map(issues, & &1.id) |> MapSet.new() == MapSet.new(["100", "200"])
    end

    test "hydrates blocked_by for every fetched issue regardless of state" do
      request_fun = fn
        %{method: :get, url: url} ->
          cond do
            URI.decode(url) =~ "labels=sym:todo" ->
              {:ok, %{status: 200, body: [todo_issue_fixture(7)]}}

            URI.decode(url) =~ "labels=sym:in-progress" ->
              {:ok, %{status: 200, body: [in_progress_issue_fixture(8)]}}

            url =~ "/issues/7/dependencies/blocked_by" ->
              blocker = %{"number" => 5, "labels" => [%{"name" => "sym:in-progress"}]}
              {:ok, %{status: 200, body: [blocker]}}

            url =~ "/issues/8/dependencies/blocked_by" ->
              blocker = %{"number" => 6, "state" => "closed", "labels" => []}
              {:ok, %{status: 200, body: [blocker]}}

            true ->
              {:ok, %{status: 200, body: []}}
          end
      end

      assert {:ok, issues} =
               Issues.fetch_issues_by_states(["todo", "in-progress"], request_fun: request_fun)

      todo_issue = Enum.find(issues, &(&1.id == "7"))
      in_progress_issue = Enum.find(issues, &(&1.id == "8"))

      assert todo_issue.blocked_by == [%{id: "5", identifier: "5", state: "in-progress"}]
      assert in_progress_issue.blocked_by == [%{id: "6", identifier: "6", state: "Closed"}]
    end

    test "filters out a blocker that references the issue itself" do
      request_fun = fn %{method: :get, url: url} ->
        cond do
          URI.decode(url) =~ "labels=sym:todo" ->
            {:ok, %{status: 200, body: [todo_issue_fixture(7)]}}

          url =~ "/issues/7/dependencies/blocked_by" ->
            self_blocker = %{"number" => 7, "labels" => [%{"name" => "sym:todo"}]}
            real_blocker = %{"number" => 5, "labels" => [%{"name" => "sym:in-progress"}]}
            {:ok, %{status: 200, body: [self_blocker, real_blocker]}}

          true ->
            {:ok, %{status: 200, body: []}}
        end
      end

      assert {:ok, [issue]} = Issues.fetch_issues_by_states(["todo"], request_fun: request_fun)
      assert issue.blocked_by == [%{id: "5", identifier: "5", state: "in-progress"}]
    end

    test "drops malformed blockers and labels while preserving valid siblings" do
      request_fun = fn %{method: :get, url: url} ->
        cond do
          URI.decode(url) =~ "labels=sym:todo" ->
            {:ok, %{status: 200, body: [todo_issue_fixture(7)]}}

          url =~ "/issues/7/dependencies/blocked_by" ->
            real_blocker = %{
              "number" => 5,
              "labels" => [%{}, %{"name" => 123}, %{"name" => "sym:in-progress"}, "bad-label"]
            }

            {:ok,
             %{
               status: 200,
               body: [
                 "not-a-map",
                 %{},
                 %{"number" => "6", "labels" => []},
                 %{"number" => 7, "labels" => "not-a-list"},
                 real_blocker,
                 nil
               ]
             }}

          true ->
            {:ok, %{status: 200, body: []}}
        end
      end

      assert {:ok, [issue]} = Issues.fetch_issues_by_states(["todo"], request_fun: request_fun)
      assert issue.blocked_by == [%{id: "5", identifier: "5", state: "in-progress"}]
    end

    test "propagates a dependency 500 instead of confirming an empty blocker list" do
      request_fun = fn
        %{method: :get, url: url} ->
          cond do
            URI.decode(url) =~ "labels=sym:todo" ->
              {:ok, %{status: 200, body: [todo_issue_fixture(9)]}}

            url =~ "/issues/9/dependencies/blocked_by" ->
              {:ok, %{status: 500, body: %{"message" => "boom"}}}

            true ->
              {:ok, %{status: 200, body: []}}
          end
      end

      assert {:error, {:github, :http, %{status: 500}}} =
               Issues.fetch_issues_by_states(["todo"], request_fun: request_fun)
    end

    test "propagates dependency permission, rate-limit, and transport failures" do
      failures = [
        {
          {:ok, %{status: 403, body: %{"message" => "forbidden"}}},
          {:github, :http, %{status: 403}}
        },
        {
          {:ok, %{status: 429, headers: [{"retry-after", "7"}], body: %{"message" => "slow down"}}},
          {:github, :rate_limited, %{status: 429, retry_after: 7, poll_interval: nil, reset_at: nil}}
        },
        {
          {:error, :econnrefused},
          {:github, :timeout, %{reason: :econnrefused}}
        }
      ]

      Enum.each(failures, fn {failure, expected} ->
        DependencyCache.clear({"owner", "repo"})

        request_fun = fn %{method: :get, url: url} ->
          if url =~ "/dependencies/blocked_by" do
            failure
          else
            {:ok, %{status: 200, body: [todo_issue_fixture(9)]}}
          end
        end

        assert Issues.fetch_issues_by_states(["todo"], request_fun: request_fun) ==
                 {:error, expected}
      end)
    end

    test "propagates rate limits and suppresses repeated dependency calls until reset" do
      calls = :counters.new(1, [])
      wall_now = ~U[2026-01-01 00:00:00Z]
      reset_at = DateTime.to_unix(~U[2026-01-01 00:01:00Z]) |> Integer.to_string()

      request_fun = fn %{method: :get, url: url} ->
        cond do
          URI.decode(url) =~ "labels=sym:todo" ->
            {:ok, %{status: 200, body: [todo_issue_fixture(9)]}}

          url =~ "/issues/9/dependencies/blocked_by" ->
            :counters.add(calls, 1, 1)

            {:ok,
             %{
               status: 200,
               headers: [
                 {"x-ratelimit-remaining", "10"},
                 {"x-ratelimit-reset", reset_at}
               ],
               body: []
             }}

          true ->
            {:ok, %{status: 200, body: []}}
        end
      end

      opts = [
        request_fun: request_fun,
        dependency_now_fun: fn -> 1_000 end,
        dependency_wall_now_fun: fn -> wall_now end
      ]

      assert {:error, {:github, :rate_limited, %{remaining: 10, reset_at: "2026-01-01T00:01:00Z", reason: :dependency_rate_budget}}} =
               Issues.fetch_issues_by_states(["todo"], opts)

      assert {:error, {:github, :rate_limited, _detail}} =
               Issues.fetch_issues_by_states(["todo"], opts)

      assert :counters.get(calls, 1) == 1
    end

    test "enforces one global dependency deadline and returns unknown rather than empty" do
      request_fun = fn %{method: :get, url: url} ->
        cond do
          URI.decode(url) =~ "labels=sym:todo" ->
            {:ok, %{status: 200, body: [todo_issue_fixture(9)]}}

          url =~ "/issues/9/dependencies/blocked_by" ->
            receive do
              :unexpected_release -> {:ok, %{status: 200, body: []}}
            after
              10_000 -> {:ok, %{status: 200, body: []}}
            end

          true ->
            {:ok, %{status: 200, body: []}}
        end
      end

      started_at = System.monotonic_time(:millisecond)

      assert {:error, {:github, :timeout, %{issue_id: "9"}}} =
               Issues.fetch_issues_by_states(["todo"],
                 request_fun: request_fun,
                 dependency_poll_deadline_ms: 25
               )

      assert System.monotonic_time(:millisecond) - started_at < 250
    end

    test "advances fairly past 200 issues without treating overflow as unblocked" do
      calls = :counters.new(1, [])
      issues = Enum.map(1..205, &todo_issue_fixture/1)

      request_fun = fn %{method: :get, url: url} ->
        if String.contains?(url, "/dependencies/blocked_by") do
          :counters.add(calls, 1, 1)
          issue_number = url |> String.split("/issues/") |> List.last() |> String.split("/") |> List.first() |> String.to_integer()

          blockers =
            if issue_number == 205 do
              [%{"number" => 999, "labels" => [%{"name" => "sym:in-progress"}]}]
            else
              []
            end

          {:ok, %{status: 200, body: blockers}}
        else
          {:ok, %{status: 200, body: issues}}
        end
      end

      opts = [
        request_fun: request_fun,
        dependency_cache_namespace: {:large_backlog, make_ref()},
        dependency_fetch_budget: 25,
        dependency_cache_ttl_ms: 60_000,
        dependency_now_fun: fn -> 1_000 end
      ]

      assert {:ok, first_poll} = Issues.fetch_issues_by_states(["todo"], opts)
      issue_205 = Enum.find(first_poll, &(&1.id == "205"))
      refute issue_205.blocked_by_known?

      assert DispatchPolicy.todo_issue_blocked_by_non_terminal?(
               issue_205,
               MapSet.new(["done"])
             )

      ninth_poll =
        Enum.reduce(2..9, first_poll, fn _poll, _previous ->
          assert {:ok, issues} = Issues.fetch_issues_by_states(["todo"], opts)
          issues
        end)

      issue_205 = Enum.find(ninth_poll, &(&1.id == "205"))
      assert issue_205.blocked_by_known?
      assert issue_205.blocked_by == [%{id: "999", identifier: "999", state: "in-progress"}]
      assert :counters.get(calls, 1) == 205

      assert {:ok, _cached_poll} = Issues.fetch_issues_by_states(["todo"], opts)
      assert :counters.get(calls, 1) == 205
    end
  end

  defp todo_issue_fixture(number) do
    %{
      "number" => number,
      "title" => "Todo issue #{number}",
      "body" => nil,
      "html_url" => "https://github.com/owner/repo/issues/#{number}",
      "labels" => [%{"name" => "sym:todo"}],
      "assignee" => nil,
      "created_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-02T00:00:00Z"
    }
  end

  defp in_progress_issue_fixture(number) do
    %{
      "number" => number,
      "title" => "In progress issue #{number}",
      "body" => nil,
      "html_url" => "https://github.com/owner/repo/issues/#{number}",
      "labels" => [%{"name" => "sym:in-progress"}],
      "assignee" => nil,
      "created_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-02T00:00:00Z"
    }
  end

  describe "fetch_issue_states_by_ids/2" do
    test "returns empty list for empty id list" do
      assert {:ok, []} = Issues.fetch_issue_states_by_ids([])
    end

    test "fetches issues by numeric id via individual requests" do
      request_fun = fn %{method: :get, url: url} ->
        if url =~ "/dependencies/blocked_by" do
          {:ok, %{status: 200, body: []}}
        else
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
      end

      assert {:ok, [issue]} =
               Issues.fetch_issue_states_by_ids(["42"], request_fun: request_fun)

      assert issue.id == "42"
      assert issue.assignee_id == "dev"
    end

    test "hydrates blocked_by so pre-dispatch revalidation sees real blocker data" do
      request_fun = fn %{method: :get, url: url} ->
        cond do
          url =~ "/issues/42/dependencies/blocked_by" ->
            blocker = %{"number" => 43, "labels" => [%{"name" => "sym:in-progress"}]}
            {:ok, %{status: 200, body: [blocker]}}

          url =~ "/issues/42" ->
            body = %{
              "number" => 42,
              "title" => "Fix bug",
              "body" => "desc",
              "html_url" => "https://github.com/owner/repo/issues/42",
              "labels" => [%{"name" => "sym:todo"}],
              "assignee" => nil,
              "created_at" => "2026-01-01T00:00:00Z",
              "updated_at" => "2026-01-02T00:00:00Z"
            }

            {:ok, %{status: 200, body: body}}
        end
      end

      assert {:ok, [issue]} =
               Issues.fetch_issue_states_by_ids(["42"], request_fun: request_fun)

      assert issue.blocked_by == [%{id: "43", identifier: "43", state: "in-progress"}]
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
