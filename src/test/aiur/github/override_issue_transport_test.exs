defmodule Aiur.GitHub.OverrideIssueTransportTest do
  use Aiur.TestSupport

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "corrective ticket creation preserves its caller attribution" do
    attrs = %{title: "Override for #12: Delivery", body: "<!-- aiur-command-override action-one -->", labels: ["agent:todo", "complexity:2"]}

    request = fn req ->
      assert req.caller == "command_override_create"
      assert req.body == %{"title" => attrs.title, "body" => attrs.body, "labels" => attrs.labels}
      {:ok, %{status: 201, body: %{"number" => 42, "html_url" => "https://github.com/owner/repo/issues/42"}}}
    end

    assert {:ok, %{"number" => 42}} = Aiur.Tracker.create_issue(attrs, caller: "command_override_create", token: "fixture-token", request_fun: request)
  end

  test "corrective reconciliation preserves its caller across all pages" do
    marker = "<!-- aiur-command-override action-one -->"
    since = DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.to_iso8601()

    request = fn req ->
      assert req.caller == "command_override_reconcile"

      if String.contains?(req.url, "page=2") do
        {:ok, %{status: 200, body: [%{"number" => 42, "html_url" => "https://github.com/owner/repo/issues/42", "body" => marker}]}}
      else
        assert req.url =~ "since="
        {:ok, %{status: 200, body: [], headers: [{"link", "<https://api.github.com/repos/owner/repo/issues?page=2>; rel=\"next\""}]}}
      end
    end

    assert {:ok, %{"number" => 42}} = Aiur.Tracker.find_issue(marker, caller: "command_override_reconcile", since: since, token: "fixture-token", request_fun: request)
  end
end
