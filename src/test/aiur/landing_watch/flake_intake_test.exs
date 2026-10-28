defmodule Aiur.LandingWatch.FlakeIntakeTest do
  use Aiur.TestSupport

  test "flake creation uses the configured parked label" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/name", tracker_label_prefix: "nuc")
    parent = self()
    journal = Path.join(System.tmp_dir!(), "flake-intake-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)

    request = fn
      %{method: :get} ->
        {:ok, %{status: 200, body: %{"items" => []}}}

      %{method: :post, body: body} ->
        send(parent, {:created, body})
        {:ok, %{status: 201, body: %{"number" => 992}}}
    end

    assert :ok =
             Aiur.LandingWatch.FlakeRecorder.record(%{module: "ExampleTest", name: "fails", job: "test", excerpt: "failure"}, %{"id" => 804}, [],
               token: "test-token",
               request_fun: request,
               journal_path: journal,
               alert_emitter: fn _, _ -> :ok end
             )

    assert_received {:created, body}
    assert body["labels"] == ["bug", "needs-triage", "nuc:parked", "flake"]
  end
end
