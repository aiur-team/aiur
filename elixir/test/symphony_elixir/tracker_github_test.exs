defmodule SymphonyElixir.GitHub.TrackerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Tracker, as: GitHubTracker
  alias SymphonyElixir.Workflow

  defmodule MockGitHubClient do
    alias SymphonyElixir.Issue

    def fetch_candidate_issues, do: {:ok, [%Issue{id: "1", identifier: "o/r#1", title: "Test"}]}
    def fetch_issues_by_states(states), do: {:ok, Enum.map(states, fn _ -> %Issue{id: "1"} end)}
    def fetch_issue_states_by_ids(ids), do: {:ok, Enum.map(ids, fn id -> %Issue{id: id} end)}
    def create_comment(_id, _body), do: :ok
    def update_issue_state(_id, _state), do: :ok
  end

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    Application.put_env(:symphony_elixir, :github_client_module, MockGitHubClient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_client_module)
      restore_env("GITHUB_TOKEN", prev_token)
    end)

    :ok
  end

  test "implements Tracker behaviour" do
    assert {:ok, _issues} = GitHubTracker.fetch_candidate_issues()
  end

  test "fetch_issues_by_states delegates to client" do
    assert {:ok, issues} = GitHubTracker.fetch_issues_by_states(["todo"])
    assert length(issues) == 1
  end

  test "fetch_issue_states_by_ids delegates to client" do
    assert {:ok, [issue]} = GitHubTracker.fetch_issue_states_by_ids(["42"])
    assert issue.id == "42"
  end

  test "create_comment delegates to client" do
    assert :ok = GitHubTracker.create_comment("42", "comment body")
  end

  test "update_issue_state delegates to client" do
    assert :ok = GitHubTracker.update_issue_state("42", "Done")
  end

  test "tracker routes to GitHub adapter when kind is github" do
    assert Tracker.adapter() == SymphonyElixir.GitHub.Tracker
  end
end
