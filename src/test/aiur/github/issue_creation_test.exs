defmodule Aiur.GitHub.IssueCreationTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.IssueCreation

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "tracker creates the nonce-marked issue and dispatch labels in one POST" do
    attrs = %{title: "Analyze experiment: Example (spec)", body: "<!-- aiur-experiment-analysis request=req-example nonce=abcdef -->", labels: ["agent:todo", "complexity:2", "experiment-analysis"]}
    parent = self()

    request_fun = fn request ->
      send(parent, {:created, request})
      {:ok, %{status: 201, body: %{"number" => 42, "html_url" => "https://github.com/owner/repo/issues/42"}}}
    end

    assert {:ok, %{"number" => 42, "url" => "https://github.com/owner/repo/issues/42"}} = Aiur.Tracker.create_issue(attrs, token: "fixture-token", request_fun: request_fun)
    assert_received {:created, request}
    assert request.method == :post
    assert request.url == "https://api.github.com/repos/owner/repo/issues"
    assert request.caller == "experiment_analysis_create"
    assert request.body == %{"title" => attrs.title, "body" => attrs.body, "labels" => attrs.labels}
    refute_received {:created, _second}
  end

  test "accepted writes lacking identity are ambiguous, and failures are returned without retry" do
    attrs = %{title: "Example", body: "Brief", labels: ["agent:todo"]}
    assert {:error, :outcome_unknown} = IssueCreation.create(attrs, token: "fixture-token", request_fun: fn _ -> {:ok, %{status: 201, body: %{}}} end)
    assert {:error, :timeout} = IssueCreation.create(attrs, token: "fixture-token", request_fun: fn _ -> {:error, :timeout} end)
    assert {:error, {:github, :http, %{status: 422}}} = IssueCreation.create(attrs, token: "fixture-token", request_fun: fn _ -> {:ok, %{status: 422, body: %{}}} end)
    assert {:error, :invalid_issue} = IssueCreation.create(%{}, [])
  end
end
