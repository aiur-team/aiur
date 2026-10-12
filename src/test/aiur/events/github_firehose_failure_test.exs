defmodule Aiur.Events.GithubFirehoseFailureTest do
  use Aiur.TestSupport
  alias Aiur.Events.{Exchange, GithubFirehose, Publisher}
  alias Aiur.Workflow

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    Publisher.set_tracked_fn(fn _ -> true end)
    ticket = Integer.to_string(System.unique_integer([:positive]))
    :ok = Exchange.subscribe("ticket.#{ticket}.pr.#")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)
      Publisher.set_tracked_fn(fn _ -> true end)
    end)

    %{ticket: ticket}
  end

  test "literal unmerged closure and reopen publish their own deduplicated topics", %{ticket: ticket} do
    assert {:ok, %{count: 1}} = poll(ticket, "closed", false)
    closed_topic = "ticket.#{ticket}.pr.closed_unmerged"
    assert_receive {:event, %{topic: ^closed_topic, pr: %{"merged" => false}}}, 500
    assert {:ok, %{count: 0}} = poll(ticket, "closed", false)
    refute_receive {:event, %{topic: ^closed_topic}}, 100
    assert {:ok, %{count: 1}} = poll(ticket, "reopened", false)
    reopened_topic = "ticket.#{ticket}.pr.reopened"
    assert_receive {:event, %{topic: ^reopened_topic}}, 500
  end

  test "sparse closed event cannot masquerade as an unmerged failure", %{ticket: ticket} do
    assert {:ok, %{count: 0}} = poll(ticket, "closed", nil)
    refute_receive {:event, _}, 100
    assert {:ok, %{count: 1}} = poll(ticket, "closed", true)
    topic = "ticket.#{ticket}.pr.merged"
    assert_receive {:event, %{topic: ^topic}}, 500
  end

  defp poll(ticket, action, merged) do
    pr = %{"number" => String.to_integer(ticket), "merged" => merged, "head" => %{"ref" => "aiur/#{ticket}", "sha" => "failure-head-#{ticket}"}}
    event = %{"type" => "PullRequestEvent", "actor" => %{"login" => "human"}, "repo" => %{"name" => "owner/repo"}, "payload" => %{"action" => action, "pull_request" => pr}}
    GithubFirehose.poll(request_fun: fn _ -> {:ok, %{status: 200, headers: [], body: [event]}} end)
  end
end
