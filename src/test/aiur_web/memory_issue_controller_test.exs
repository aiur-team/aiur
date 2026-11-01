defmodule AiurWeb.MemoryIssueControllerTest do
  use Aiur.TestSupport

  import Plug.Conn
  import Plug.Test

  alias Aiur.Issue
  alias Aiur.Memory.Tracker

  setup do
    Aiur.TestSupport.start_owned_endpoint!()
    root = Application.fetch_env!(:aiur, :test_run_root)
    token_path = Path.join(root, "memory-issue-tokens-#{System.unique_integer([:positive])}.json")
    previous_token_path = Application.get_env(:aiur, :client_tokens_path)
    previous_issues = Application.get_env(:aiur, :memory_tracker_issues)
    Application.put_env(:aiur, :client_tokens_path, token_path)
    assert {:ok, token} = Aiur.ClientTokens.create("memory-seeder-#{System.unique_integer([:positive])}", "write")

    on_exit(fn ->
      if previous_token_path,
        do: Application.put_env(:aiur, :client_tokens_path, previous_token_path),
        else: Application.delete_env(:aiur, :client_tokens_path)

      if previous_issues,
        do: Application.put_env(:aiur, :memory_tracker_issues, previous_issues),
        else: Application.delete_env(:aiur, :memory_tracker_issues)

      Aiur.TestCleanup.rm_rf!(token_path)
    end)

    %{token: token}
  end

  test "an authenticated request seeds a pollable issue", %{token: token} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:aiur, :memory_tracker_issues, [])

    response = request(token, issue_payload())

    assert response.status == 201
    assert %{"issue" => %{"id" => "script-1", "identifier" => "DEMO-1"}} = Jason.decode!(response.resp_body)

    assert {:ok, [%Issue{id: "script-1", identifier: "DEMO-1", blocked_by: [%{id: "prior", state: "open"}]}]} =
             Tracker.fetch_candidate_issues()
  end

  test "the endpoint is unavailable for another tracker", %{token: token} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github")

    response = request(token, issue_payload())
    assert response.status == 404
  end

  test "invalid fields return a 422 naming the field", %{token: token} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    response = request(token, Map.delete(issue_payload(), "title"))
    assert response.status == 422
    assert Jason.decode!(response.resp_body)["error"]["message"] =~ "title"
  end

  test "a JSON value with the wrong shape returns a 422 naming id", %{token: token} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    response = request(token, [])
    assert response.status == 422
    assert Jason.decode!(response.resp_body)["error"]["message"] =~ "id"
  end

  test "duplicate id or identifier return 409", %{token: token} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:aiur, :memory_tracker_issues, [%Issue{id: "script-1", identifier: "DEMO-1"}])

    assert request(token, issue_payload()).status == 409
    assert request(token, Map.put(issue_payload(), "id", "script-2")).status == 409
  end

  defp request(token, payload) do
    conn(:post, "/api/v1/memory/issues", Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("origin", "http://127.0.0.1")
    |> put_req_header("x-aiur-request", "1")
    |> AiurWeb.Endpoint.call(AiurWeb.Endpoint.init([]))
  end

  defp issue_payload do
    %{
      "id" => "script-1",
      "identifier" => "DEMO-1",
      "title" => "Seeded by a script",
      "description" => "Run the fake provider",
      "state" => "todo",
      "labels" => ["agent:todo"],
      "blocked_by" => [%{"id" => "prior", "state" => "open"}]
    }
  end
end
