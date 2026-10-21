defmodule Aiur.Orchestrator.StaleApprovedHeadTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.{StaleApprovedHead, State}

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
    assert_received {:graphql, "AiurStaleApprovedHead", %{"number" => 77}}
    assert_received {:graphql, "AiurLandingWithdrawal", %{"number" => 77}}
    assert_received {:graphql, "AiurDisableAutoMerge", %{"id" => "PR_77"}}
    refute_received {:graphql, "AiurDequeuePullRequest", _}
    assert_received {:classifier_args, "approved-head", "new-head", 77}

    assert {:event, %{"needs_attention" => true, "reason" => reason, topic: ^topic}} =
             receive_barrier({:event, %{"needs_attention" => true, "reason" => _, topic: ^topic}})

    assert reason =~ "lib/new.ex"
  end

  test "identical contribution does not withdraw auto-merge" do
    parent = self()
    assert :ok = StaleApprovedHead.reconcile("42", 77, opts(parent, :identical))
    assert_received {:graphql, "AiurStaleApprovedHead", _}
    refute_received {:graphql, "AiurLandingWithdrawal", _}
    refute_received {:graphql, "AiurDisableAutoMerge", _}
    assert_received {:classifier_args, "approved-head", "new-head", 77}
  end

  test "a transient approval read failure is retried before the changed head is withdrawn" do
    parent = self()
    base_request = opts(parent, {:changed, %{reason: :contribution_changed, hunks: [%{file: "lib/new.ex"}]}})[:request_fun]
    failures_left = :atomics.new(1, signed: false)
    :atomics.put(failures_left, 1, 1)

    request_fun = fn req ->
      if String.contains?(req.body["query"], "AiurStaleApprovedHead") and :atomics.exchange(failures_left, 1, 0) == 1 do
        send(parent, :approval_read_failed_once)
        {:error, :timeout}
      else
        base_request.(req)
      end
    end

    assert :ok =
             StaleApprovedHead.reconcile(
               "42",
               77,
               opts(parent, {:changed, %{reason: :contribution_changed, hunks: [%{file: "lib/new.ex"}]}})
               |> Keyword.put(:request_fun, request_fun)
               |> Keyword.put(:read_retry_delay_ms, 0)
             )

    assert_received :approval_read_failed_once
    assert_received {:graphql, "AiurStaleApprovedHead", _}
    assert_received {:graphql, "AiurDisableAutoMerge", _}
  end

  test "the orchestrator runs the synchronize reconciliation and alerts when GitHub auth is unavailable" do
    ticket = "stale-approved-handler-#{System.unique_integer([:positive])}"
    topic = "ticket.#{ticket}.agent.attention.landing_withdrawal_failed"
    :ok = Exchange.subscribe(topic)
    on_exit(fn -> Exchange.unsubscribe(topic) end)

    token_cache_key = {Aiur.GitHub.Access.Token, :resolved_token}
    previous_token = System.get_env("GITHUB_TOKEN")
    previous_cached_token = :persistent_term.get(token_cache_key, :unset)
    System.delete_env("GITHUB_TOKEN")
    :persistent_term.erase(token_cache_key)

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)

      case previous_cached_token do
        :unset -> :persistent_term.erase(token_cache_key)
        token -> :persistent_term.put(token_cache_key, token)
      end
    end)

    assert {:noreply, %State{}} = Aiur.Orchestrator.handle_info({:github_pr_synchronize, ticket, 77}, %State{})
    assert {:event, %{"needs_attention" => true, "reason" => reason, topic: ^topic}} = receive_barrier({:event, %{"needs_attention" => true, "reason" => _, topic: ^topic}})
    assert reason =~ "missing_github_token"
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
      contribution_classifier: fn approved, head, pr, _opts ->
        send(parent, {:classifier_args, approved, head, pr})
        verdict
      end
    ]
  end
end
