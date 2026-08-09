defmodule Aiur.GitHub.TrackerTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Tracker, as: GitHubTracker
  alias Aiur.Workflow

  defmodule MockGitHubClient do
    alias Aiur.Issue

    def fetch_candidate_issues, do: {:ok, [%Issue{id: "1", identifier: "o/r#1", title: "Test"}]}
    def fetch_issues_by_states(states), do: fetch_issues_by_states(states, [])
    def fetch_issues_by_states(states, _opts), do: {:ok, Enum.map(states, fn _ -> %Issue{id: "1"} end)}
    def fetch_issue_states_by_ids(ids), do: {:ok, Enum.map(ids, fn id -> %Issue{id: id} end)}

    def fetch_issue_states_by_ids_conditional(ids, cache) do
      {:ok, Enum.map(ids, fn id -> %Issue{id: id} end), Map.put(cache, :conditional?, true)}
    end

    def create_comment(_id, _body), do: :ok
    def update_issue_state(_id, _state), do: :ok
  end

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    Application.put_env(:aiur, :github_client_module, MockGitHubClient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    on_exit(fn ->
      Application.delete_env(:aiur, :github_client_module)
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

  test "fetch_issue_states_by_ids_conditional delegates with the persistent cache" do
    assert {:ok, [issue], %{existing: true, conditional?: true}} =
             GitHubTracker.fetch_issue_states_by_ids_conditional(["42"], %{existing: true})

    assert issue.id == "42"
  end

  test "create_comment delegates to client" do
    assert :ok = GitHubTracker.create_comment("42", "comment body")
  end

  test "update_issue_state delegates to client" do
    assert :ok = GitHubTracker.update_issue_state("42", "Done")
  end

  test "fenced update fails closed when the configured client lacks update_issue_state/3" do
    assert {:error, :expected_state_unsupported} =
             GitHubTracker.update_issue_state("42", "ci-wait", expected_state: "human-review")
  end

  test "tracker routes to GitHub adapter when kind is github" do
    assert Tracker.adapter() == Aiur.GitHub.Tracker
  end
end
