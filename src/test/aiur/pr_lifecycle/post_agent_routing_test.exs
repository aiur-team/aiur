defmodule Aiur.PRLifecycle.PostAgentRoutingTest do
  use Aiur.TestSupport

  alias Aiur.PRLifecycle.PostAgentRouting
  alias Aiur.Workflow

  defmodule Client do
    def fetch_classified_pr_reviews(6053),
      do: {:ok, [%{"state" => "CHANGES_REQUESTED", "commit_id" => "head", "user" => %{"login" => "r"}, "submitted_at" => "t", "id" => 1, authoritative: true}]}
  end

  # #6053: turn completion forwards `reviews_fetcher: nil`; route/3 must fall back to the code host.
  test "a nil reviews_fetcher uses the default code host fetcher" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    previous = Application.get_env(:aiur, :github_client_module)
    Application.put_env(:aiur, :github_client_module, Client)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :github_client_module, previous), else: Application.delete_env(:aiur, :github_client_module)
    end)

    pr = %{"number" => 6053, "head" => %{"sha" => "head"}}
    assert PostAgentRouting.route(pr, "human-review", reviews_fetcher: nil) == "rework"
  end
end
