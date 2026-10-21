defmodule Aiur.GitHub.StaleApprovedHeadTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.GitHub.StaleApprovedHead

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "changed approved contribution disables auto-merge and alerts with the changed path" do
    ticket = "stale-approved-push-#{System.unique_integer([:positive])}"
    topic = "ticket.#{ticket}.agent.attention.stale_approved_pr_head"
    :ok = Exchange.subscribe(topic)
    on_exit(fn -> Exchange.unsubscribe(topic) end)
    parent = self()
    opts = opts(parent, {:changed, %{reason: :contribution_changed, hunks: [%{file: "lib/new.ex"}]}})

    assert :ok = StaleApprovedHead.reconcile(ticket, 77, opts)
    assert_received {:graphql, "AiurStaleApprovedHead", _}
    assert_received {:graphql, "AiurLandingWithdrawal", _}
    assert_received {:graphql, "AiurDisableAutoMerge", _}
    refute_received {:graphql, "AiurDequeuePullRequest", _}
    assert_receive {:event, %{"needs_attention" => true, "reason" => reason, topic: ^topic}}, 500
    assert reason =~ "lib/new.ex"
  end

  test "identical contribution does not withdraw auto-merge" do
    parent = self()
    assert :ok = StaleApprovedHead.reconcile("42", 77, opts(parent, :identical))
    assert_received {:graphql, "AiurStaleApprovedHead", _}
    refute_received {:graphql, "AiurLandingWithdrawal", _}
    refute_received {:graphql, "AiurDisableAutoMerge", _}
  end

  defp opts(parent, verdict) do
    request_fun = fn req ->
      query = req.body["query"]
      variables = req.body["variables"]
      [operation] = Regex.run(~r/(?:query|mutation) (\w+)/, query, capture: :all_but_first)
      send(parent, {:graphql, operation, variables})

      data =
        case operation do
          "AiurStaleApprovedHead" ->
            %{
              "repository" => %{
                "pullRequest" => %{
                  "state" => "OPEN",
                  "headRefOid" => "new-head",
                  "reviewDecision" => "APPROVED",
                  "autoMergeRequest" => %{"enabledAt" => "now"},
                  "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "approved-head"}}]}
                }
              }
            }

          "AiurLandingWithdrawal" ->
            %{"repository" => %{"pullRequest" => %{"id" => "PR_77", "mergeQueueEntry" => %{"id" => "MQE_1"}, "autoMergeRequest" => %{"enabledAt" => "now"}}}}

          "AiurDisableAutoMerge" ->
            %{"disablePullRequestAutoMerge" => %{"pullRequest" => %{"id" => "PR_77"}}}
        end

      {:ok, %{status: 200, body: %{"data" => data}}}
    end

    [
      request_fun: request_fun,
      token: "test-token",
      contribution_classifier: fn _approved, _head, _pr, _opts -> verdict end
    ]
  end
end
