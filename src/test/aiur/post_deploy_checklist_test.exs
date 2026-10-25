defmodule Aiur.PostDeployChecklistTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.Exchange
  alias Aiur.PostDeployChecklist

  @tag :tmp_dir
  test "records merged PR checks once and keeps completion across restart", %{tmp_dir: dir} do
    path = Path.join(dir, "checks.json")
    exchange = start_supervised!({Exchange, name: nil}, id: :post_deploy_exchange)
    Phoenix.PubSub.subscribe(Aiur.PubSub, "post_deploy_checks")
    start_supervised!({PostDeployChecklist, name: :post_deploy_test, path: path, exchange: exchange}, id: :post_deploy_test)

    event = %{
      topic: "ticket.42.pr.merged",
      repository: "aiur-team/aiur",
      pr: %{
        "number" => 91,
        "html_url" => "https://github.com/aiur-team/aiur/pull/91",
        "merged_at" => "2026-10-14T12:00:00Z",
        "user" => %{"login" => "contributor"},
        "head" => %{"repo" => %{"full_name" => "aiur-team/aiur"}}
      },
      post_deploy_checks: ["dictate start run and confirm the dashboard shows it (operator: physical Stream Deck)"]
    }

    assert Exchange.publish("ticket.42.pr.merged", event, exchange) == 1
    assert Exchange.publish("ticket.42.pr.merged", event, exchange) == 1
    [check] = PostDeployChecklist.list(:post_deploy_test)
    assert check["text"] == "dictate start run and confirm the dashboard shows it"
    assert check["operator"] == "physical Stream Deck"
    assert check["pr_number"] == 91
    assert check["pr_url"] == "https://github.com/aiur-team/aiur/pull/91"
    assert check["pr_author"] == "contributor"
    assert is_nil(check["done_at"])

    assert :ok = PostDeployChecklist.mark_done(check["id"], "executor", :post_deploy_test)
    assert :ok = PostDeployChecklist.mark_done(check["id"], "retrying-executor", :post_deploy_test)
    assert [%{"done_by" => "executor", "done_at" => done_at}] = PostDeployChecklist.list(:post_deploy_test)
    assert_receive {:post_deploy_checks_updated, [%{"done_by" => "executor", "done_at" => ^done_at}]}, 500
    assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(done_at)

    stop_supervised!(:post_deploy_test)
    start_supervised!({PostDeployChecklist, name: :post_deploy_recovered, path: path, exchange: exchange}, id: :post_deploy_recovered)
    assert [%{"done_by" => "executor", "done_at" => ^done_at, "text" => "dictate start run and confirm the dashboard shows it"}] = PostDeployChecklist.list(:post_deploy_recovered)
  end

  @tag :tmp_dir
  test "ignores merged PRs without post-deploy lines", %{tmp_dir: dir} do
    exchange = start_supervised!({Exchange, name: nil}, id: :post_deploy_empty_exchange)
    start_supervised!({PostDeployChecklist, name: :post_deploy_empty, path: Path.join(dir, "checks.json"), exchange: exchange}, id: :post_deploy_empty)

    assert Exchange.publish("ticket.42.pr.closed_unmerged", %{topic: "ticket.42.pr.closed_unmerged", pr: %{"body" => "Post-deploy check: do something"}}, exchange) == 0
    assert :ok = PostDeployChecklist.ingest(%{pr: %{"body" => "## Local tests\n- `mix test` -> passed"}}, :post_deploy_empty)
    assert PostDeployChecklist.list(:post_deploy_empty) == []
  end

  @tag :tmp_dir
  test "reports unreadable persisted state and uses the base repository for forked PRs", %{tmp_dir: dir} do
    path = Path.join(dir, "checks.json")
    File.mkdir_p!(dir)
    File.write!(path, "not-json")
    start_supervised!({PostDeployChecklist, name: :post_deploy_invalid, path: path, subscribe?: false})
    assert {:error, _reason} = PostDeployChecklist.status(:post_deploy_invalid)
    assert PostDeployChecklist.list(:post_deploy_invalid) == []

    path = Path.join(dir, "fork-checks.json")
    exchange = start_supervised!({Exchange, name: nil}, id: :post_deploy_fork_exchange)
    start_supervised!({PostDeployChecklist, name: :post_deploy_fork, path: path, exchange: exchange}, id: :post_deploy_fork)

    event = %{
      topic: "ticket.91.pr.merged",
      repository: "upstream/project",
      pr: %{"number" => 12, "head" => %{"repo" => %{"full_name" => "contributor/project"}}, "user" => %{"login" => "contributor"}},
      post_deploy_checks: ["run the smoke check"]
    }

    assert :ok = PostDeployChecklist.ingest(event, :post_deploy_fork)

    assert [%{"repository" => "upstream/project", "pr_author" => "contributor", "pr_url" => "https://github.com/upstream/project/pull/12"}] =
             PostDeployChecklist.list(:post_deploy_fork)
  end
end
