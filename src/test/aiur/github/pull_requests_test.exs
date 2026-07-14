defmodule Aiur.GitHub.PullRequestsTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.PullRequests

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
      tracker_repo: "owner/repo"
    )

    :ok
  end

  describe "fetch_pull_request_changed_paths/2" do
    test "returns filenames from files endpoint" do
      files = [
        %{"filename" => "lib/foo.ex", "status" => "modified"},
        %{"filename" => "test/foo_test.exs", "status" => "added"}
      ]

      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/pulls/42/files"
        {:ok, %{status: 200, body: files, headers: []}}
      end

      assert {:ok, ["lib/foo.ex", "test/foo_test.exs"]} =
               PullRequests.fetch_pull_request_changed_paths(42, request_fun: request_fun)
    end
  end

  describe "fetch_pull_request_head_ref/2" do
    test "returns head ref from PR response" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/pulls/10"
        {:ok, %{status: 200, body: %{"head" => %{"ref" => "aiur/10"}}}}
      end

      assert {:ok, "aiur/10"} =
               PullRequests.fetch_pull_request_head_ref(10, request_fun: request_fun)
    end

    test "returns :head_ref_missing when head ref absent from body" do
      request_fun = fn _ -> {:ok, %{status: 200, body: %{"head" => %{}}}} end
      assert {:error, :head_ref_missing} = PullRequests.fetch_pull_request_head_ref(1, request_fun: request_fun)
    end
  end

  describe "ensure_base_branch/3" do
    test "leaves a correctly targeted pull request unchanged" do
      request_fun = fn _request -> flunk("a matching base must not call GitHub") end

      pr = %{
        "number" => 42,
        "draft" => true,
        "base" => %{"ref" => "main"}
      }

      assert {:ok, :unchanged} =
               PullRequests.ensure_base_branch(pr, "main", request_fun: request_fun)
    end

    test "repairs only the base of a pre-existing draft pull request" do
      request_fun = fn %{method: :patch, url: url, body: body} ->
        assert String.ends_with?(url, "/repos/owner/repo/pulls/1144")
        assert body == %{"base" => "main"}

        {:ok,
         %{
           status: 200,
           body: %{
             "number" => 1144,
             "draft" => true,
             "base" => %{"ref" => "main"}
           }
         }}
      end

      pr = %{
        "number" => 1144,
        "draft" => true,
        "base" => %{"ref" => "v2"}
      }

      assert {:ok, :repaired} =
               PullRequests.ensure_base_branch(pr, "main", request_fun: request_fun)
    end

    test "returns observed and expected bases when repair fails" do
      request_fun = fn %{method: :patch, body: %{"base" => "main"}} ->
        {:ok, %{status: 422, body: %{"message" => "base is invalid"}}}
      end

      pr = %{
        "number" => 1145,
        "draft" => true,
        "base" => %{"ref" => "v2"}
      }

      assert {:error,
              {:pull_request_base_repair_failed,
               %{
                 pr_number: 1145,
                 current_base: "v2",
                 expected_base: "main",
                 reason: {:github, :http, %{status: 422}}
               }}} = PullRequests.ensure_base_branch(pr, "main", request_fun: request_fun)
    end
  end

  describe "pull_request_has_label?/2" do
    test "returns true when PR carries the label" do
      pr = %{"labels" => [%{"name" => "agent:watch"}]}
      assert PullRequests.pull_request_has_label?(pr, "agent:watch")
    end

    test "returns false when label absent" do
      pr = %{"labels" => [%{"name" => "other"}]}
      refute PullRequests.pull_request_has_label?(pr, "agent:watch")
    end

    test "returns false when no labels key" do
      refute PullRequests.pull_request_has_label?(%{}, "agent:watch")
    end
  end

  describe "open_pull_request_or_nil/1" do
    test "returns the PR for open state" do
      pr = %{"state" => "open", "number" => 5}
      assert PullRequests.open_pull_request_or_nil(pr) == pr
    end

    test "returns nil for closed/merged PR" do
      assert PullRequests.open_pull_request_or_nil(%{"state" => "closed"}) == nil
      assert PullRequests.open_pull_request_or_nil(%{"state" => "merged"}) == nil
    end
  end
end
