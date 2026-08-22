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
             "base" => %{"ref" => "main"},
             "head" => %{"sha" => "confirmed-head"}
           }
         }}
      end

      pr = %{
        "number" => 1144,
        "draft" => true,
        "base" => %{"ref" => "v2"}
      }

      assert {:ok, {:repaired, "confirmed-head"}} =
               PullRequests.ensure_base_branch(pr, "main",
                 request_fun: request_fun,
                 before_base_repair_fun: fn -> :ok end
               )
    end

    test "does not mutate GitHub when the pre-repair journal fails" do
      request_fun = fn _request -> flunk("PATCH must not run without a durable journal") end

      pr = %{
        "number" => 1144,
        "draft" => true,
        "base" => %{"ref" => "v2"}
      }

      assert {:error,
              {:pull_request_base_repair_failed,
               %{
                 repair_journaled: false,
                 reason: {:base_repair_journal_failed, :disk_full}
               }}} =
               PullRequests.ensure_base_branch(pr, "main",
                 request_fun: request_fun,
                 before_base_repair_fun: fn -> {:error, :disk_full} end
               )
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
               }}} =
               PullRequests.ensure_base_branch(pr, "main",
                 request_fun: request_fun,
                 before_base_repair_fun: fn -> :ok end
               )
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

  describe "fetch_open_pull_requests_by_label_conditional/2" do
    # Acceptance criterion 1 for watch-target discovery (#2069): the per-cycle
    # read of the open-pull-request collection carries If-None-Match, so an
    # unchanged collection is a `304` GitHub does not bill against the primary
    # REST limit instead of a full-price `200` re-read of every open PR.
    test "returns the labelled pull requests and the response ETag on a 200" do
      prs = [
        %{"number" => 11, "labels" => [%{"name" => "agent:watch"}]},
        %{"number" => 12, "labels" => [%{"name" => "other"}]}
      ]

      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/pulls?"
        {:ok, %{status: 200, body: prs, headers: [{"etag", ~s("v1")}]}}
      end

      assert {:ok, [%{"number" => 11}], ~s("v1")} =
               PullRequests.fetch_open_pull_requests_by_label_conditional("agent:watch",
                 request_fun: request_fun
               )
    end

    test "sends If-None-Match and returns :not_modified on a 304" do
      parent = self()

      request_fun = fn request ->
        send(parent, {:requested, request})
        {:ok, %{status: 304, headers: [{"etag", ~s("v2")}]}}
      end

      assert {:not_modified, ~s("v2")} =
               PullRequests.fetch_open_pull_requests_by_label_conditional("agent:watch",
                 request_fun: request_fun,
                 etag: ~s("v1")
               )

      assert_receive {:requested, request}
      assert request.etag == ~s("v1")
    end

    # #2330: the open-PR listing is created desc, so a label added to an older
    # PR lands on page 2+ while page 1 answers 304 forever. A paginated read
    # therefore drops its validator — the next discovery reads unconditionally
    # rather than trust a page-1 `304` for a multi-page question.
    test "drops the validator once the listing paginates" do
      next =
        ~s(<https://api.github.com/repos/owner/repo/pulls?state=open&per_page=100&page=2>; rel="next")

      request_fun = fn %{method: :get, url: url} ->
        if String.contains?(url, "page=2") do
          {:ok, %{status: 200, body: [%{"number" => 12, "labels" => [%{"name" => "agent:watch"}]}], headers: []}}
        else
          {:ok,
           %{
             status: 200,
             body: [%{"number" => 11, "labels" => [%{"name" => "agent:watch"}]}],
             headers: [{"etag", ~s("v1")}, {"link", next}]
           }}
        end
      end

      assert {:ok, [%{"number" => 11}, %{"number" => 12}], nil} =
               PullRequests.fetch_open_pull_requests_by_label_conditional("agent:watch",
                 request_fun: request_fun
               )
    end
  end
end
