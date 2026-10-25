defmodule Aiur.CodeHostTest do
  use Aiur.TestSupport

  alias Aiur.{CodeHost, Workflow}
  alias Aiur.Tracker.NullCodeHost

  defmodule Client do
    def fetch_classified_pr_review_comments(value), do: {:ok, [%{comment: value}]}
    def fetch_classified_pr_reviews(value), do: {:error, {:reviews, value}}
    def fetch_unaddressed_pr_review_thread_comments(value), do: {:ok, [%{thread: value}]}
    def fetch_open_pull_request_for_branch(value), do: {:ok, %{branch: value}}
    def fetch_open_pull_requests_for_branch(value), do: {:ok, [%{branch: value}]}
  end

  test "null code host preserves memory and Linear PR evidence" do
    for kind <- ["memory", "linear"] do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: kind)
      assert CodeHost.adapter() == NullCodeHost
      assert {:ok, []} = CodeHost.fetch_classified_pr_review_comments("1")
      assert {:ok, []} = CodeHost.fetch_classified_pr_reviews("1")
      assert {:ok, []} = CodeHost.fetch_unaddressed_pr_review_thread_comments("1")
      assert {:ok, []} = CodeHost.fetch_open_pull_requests_for_branch("1")
      assert {:ok, nil} = CodeHost.fetch_open_pull_request_for_branch("1")
    end
  end

  test "code host is available only for the GitHub tracker" do
    for kind <- ["memory", "linear", "github"] do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: kind, tracker_repo: "owner/repo")
      assert CodeHost.available?() == (kind == "github")
    end
  end

  test "GitHub code host forwards arguments and results including errors" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    previous = Application.get_env(:aiur, :github_client_module)
    Application.put_env(:aiur, :github_client_module, Client)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :github_client_module, previous), else: Application.delete_env(:aiur, :github_client_module)
    end)

    assert CodeHost.adapter() == Aiur.GitHub.Tracker
    assert {:ok, [%{comment: 12}]} = CodeHost.fetch_classified_pr_review_comments(12)
    assert {:error, {:reviews, 12}} = CodeHost.fetch_classified_pr_reviews(12)
    assert {:ok, [%{thread: 12}]} = CodeHost.fetch_unaddressed_pr_review_thread_comments(12)
    assert {:ok, %{branch: "ticket"}} = CodeHost.fetch_open_pull_request_for_branch("ticket")
    assert {:ok, [%{branch: "ticket"}]} = CodeHost.fetch_open_pull_requests_for_branch("ticket")
  end

  # Future compatibility guard: these results already passed before the split.
  test "deprecated Tracker PR delegates preserve their public return values" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    for function <- [:fetch_classified_pr_review_comments, :fetch_classified_pr_reviews, :fetch_unaddressed_pr_review_thread_comments, :fetch_open_pull_requests_for_branch] do
      fetch = Function.capture(Aiur.Tracker, function, 1)
      assert {:ok, []} = fetch.("1")
    end

    fetch = Function.capture(Aiur.Tracker, :fetch_open_pull_request_for_branch, 1)
    assert {:ok, nil} = fetch.("1")
  end
end
