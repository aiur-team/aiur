defmodule Aiur.GitHub.Issues.ConditionalTest do
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

          String.contains?(url, "/issues/42/timeline?per_page=") ->
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

          String.contains?(url, "/issues/142/timeline?per_page=") ->
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
