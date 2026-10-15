defmodule Aiur.GitHub.IssueState.LabelsTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.IssueState
  alias Aiur.GitHub.ResourceStore

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

    ResourceStore.reset()
    on_exit(&ResourceStore.reset/0)
    :ok
  end

  describe "add_label/3" do
    test "returns :ok for 200..299 responses" do
      for status <- [200, 201, 204] do
        request_fun = fn _ -> {:ok, %{status: status}} end
        assert :ok = IssueState.add_label("42", "sym:watch", request_fun: request_fun)
      end
    end

    test "returns error for non-2xx responses" do
      request_fun = fn _ -> {:ok, %{status: 404, body: %{}, headers: []}} end
      assert {:error, _} = IssueState.add_label("42", "sym:watch", request_fun: request_fun)
    end
  end

  describe "remove_label/3" do
    test "treats 404 as success (idempotent delete)" do
      request_fun = fn _ -> {:ok, %{status: 404}} end
      assert :ok = IssueState.remove_label("42", "sym:todo", request_fun: request_fun)
    end

    test "returns :ok for 200" do
      request_fun = fn _ -> {:ok, %{status: 200}} end
      assert :ok = IssueState.remove_label("42", "sym:todo", request_fun: request_fun)
    end

    test "returns error for non-2xx/non-404 responses" do
      request_fun = fn _ -> {:ok, %{status: 500, body: %{}, headers: []}} end
      assert {:error, _} = IssueState.remove_label("42", "sym:todo", request_fun: request_fun)
    end
  end

  describe "preserved_prefixed_label?/2" do
    test "preserves automatic fallback markers across workflow state changes" do
      assert IssueState.preserved_prefixed_label?("sym:rate-limit-fallback", "sym")
      assert IssueState.preserved_prefixed_label?(" SYM:RATE-LIMIT-FALLBACK ", "sym")
      refute IssueState.preserved_prefixed_label?("sym:in-progress", "sym")
    end
  end
end
