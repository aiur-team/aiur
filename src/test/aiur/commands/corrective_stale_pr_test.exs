defmodule Aiur.Commands.CorrectiveStalePrTest do
  use Aiur.TestSupport

  alias Aiur.Commands.CorrectiveTicket
  alias Aiur.{Decision, DecisionAnswer, DecisionRevision, Issue, Tracker, Workflow}
  alias Aiur.GitHub.ResourceStore

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.reset()
    on_exit(fn -> ResourceStore.reset() end)
    now = DateTime.utc_now()
    old = struct(DecisionAnswer, action_id: "old", custom_response: "blue")
    answer = struct(DecisionAnswer, action_id: "override", custom_response: "green")
    revision = struct(DecisionRevision, action_id: "override", prior_action_id: "old", answer: answer, recorded_at: now)
    record = %{action_id: "override", route: :resume_pending, pr_merged: :unknown, state: :queued, ticket: %{identifier: "50"}}
    decision = struct(Decision, decision_id: "command", ticket: record.ticket, question: "Colour?", short_label: "Colour", answer: old, revisions: [revision], overrides: [record])
    %{decision: decision, record: record}
  end

  test "a closed ticket with missing or stale delivered PR evidence creates exactly one corrective ticket", ctx do
    for cache <- [:missing, :stale] do
      ResourceStore.reset()
      if cache == :stale, do: stale_cache()
      assert {:ok, nil} = Tracker.ticket_pull_request("50")
      {:ok, storage} = Agent.start_link(fn -> %{ticket: nil, creates: 0, reads: 0} end)
      opts = options(storage)
      assert {:ok, [first]} = CorrectiveTicket.reconcile(ctx.decision, ctx.record, opts)
      assert {:override_corrective_ticket, %{ticket: %{identifier: "70"}, pr_number: 60, merge_commit_sha: "merged-days-ago"}} = first
      assert {:ok, [^first]} = CorrectiveTicket.reconcile(ctx.decision, ctx.record, opts)
      assert Agent.get(storage, & &1.creates) == 1
      assert Agent.get(storage, & &1.reads) == 2
      Agent.stop(storage)
    end
  end

  test "cache expiry after a merged route was accepted still creates its corrective ticket", ctx do
    stale_cache()
    {:ok, storage} = Agent.start_link(fn -> %{ticket: nil, creates: 0, reads: 0} end)
    record = %{ctx.record | route: :corrective_ticket, pr_merged: true}
    decision = %{ctx.decision | overrides: [record]}
    assert {:ok, [{:override_corrective_ticket, %{merge_commit_sha: "merged-days-ago"}}]} = CorrectiveTicket.reconcile(decision, record, options(storage))
    assert Agent.get(storage, & &1.creates) == 1
  end

  test "open tickets never trigger the remote merged PR lookup", ctx do
    {:ok, storage} = Agent.start_link(fn -> %{ticket: nil, creates: 0, reads: 0} end)
    opts = options(storage) |> Keyword.put(:issue_closure, fn "50", _ -> {:ok, %{open?: true}} end)
    assert {:ok, []} = CorrectiveTicket.reconcile(ctx.decision, ctx.record, opts)
    assert Agent.get(storage, &{&1.creates, &1.reads}) == {0, 0}
  end

  test "an incomplete remote PR lookup cannot authorize ticket creation", ctx do
    {:ok, storage} = Agent.start_link(fn -> %{ticket: nil, creates: 0, reads: 0} end)
    opts = options(storage) |> Keyword.put(:resolve_pull_request, fn "50", _ -> Tracker.resolve_ticket_pull_request("50", token: "fixture", request_fun: fn _ -> response(true) end) end)
    assert {:error, :incomplete_merged_pr_lookup} = CorrectiveTicket.reconcile(ctx.decision, ctx.record, opts)
    assert Agent.get(storage, & &1.creates) == 0
  end

  test "a foreign merged PR cannot authorize a corrective ticket in this repository", ctx do
    {:ok, storage} = Agent.start_link(fn -> %{ticket: nil, creates: 0, reads: 0} end)
    opts = options(storage) |> Keyword.put(:resolve_pull_request, resolver([node("other/repository", 99, "foreign-merge")]))
    assert {:ok, [{:override_corrective_closed, %{action_id: "override"}}]} = CorrectiveTicket.reconcile(ctx.decision, ctx.record, opts)
    assert Agent.get(storage, & &1.creates) == 0
    assert Agent.get(storage, & &1.ticket) == nil
    record = %{ctx.record | route: :corrective_ticket}
    assert {:ok, [{:override_corrective_closed, %{action_id: "override"}}]} = CorrectiveTicket.reconcile(%{ctx.decision | overrides: [record]}, record, opts)
  end

  test "mixed closing PRs preserve the configured repository identity before picking the latest merge", ctx do
    {:ok, storage} = Agent.start_link(fn -> %{ticket: nil, creates: 0, reads: 0} end)
    foreign = node("other/repository", 99, "foreign-merge") |> Map.put("mergedAt", DateTime.utc_now() |> DateTime.to_iso8601())
    opts = options(storage) |> Keyword.put(:resolve_pull_request, resolver([node("OWNER/REPO", 60, "own-merge"), foreign]))
    assert {:ok, [{:override_corrective_ticket, %{pr_number: 60, merge_commit_sha: "own-merge"}}]} = CorrectiveTicket.reconcile(ctx.decision, ctx.record, opts)
    assert Agent.get(storage, & &1.creates) == 1
    assert Agent.get(storage, & &1.ticket["body"]) =~ "own-merge"
    refute Agent.get(storage, & &1.ticket["body"]) =~ "foreign-merge"
  end

  defp options(storage) do
    [
      issue_closure: fn "50", _ -> {:ok, %{open?: false}} end,
      issues: fn ["50"] -> {:ok, [%Issue{state: "Closed", labels: ["feature:colour"]}]} end,
      resolve_pull_request: fn "50", _opts ->
        Tracker.resolve_ticket_pull_request("50",
          token: "fixture",
          request_fun: fn request ->
            assert request.caller == "command_override_merged_pr"
            assert request.body["variables"] == %{"owner" => "owner", "repository" => "repo", "number" => 50}
            assert request.body["query"] =~ "closedByPullRequestsReferences"
            Agent.update(storage, &%{&1 | reads: &1.reads + 1})
            response(false)
          end
        )
      end,
      find: fn _marker, _opts -> {:ok, Agent.get(storage, & &1.ticket)} end,
      create: fn attrs, _opts ->
        ticket = %{"number" => 70, "url" => "https://github.com/owner/repo/issues/70", "body" => attrs.body}
        Agent.update(storage, &%{&1 | creates: &1.creates + 1, ticket: ticket})
        {:ok, ticket}
      end,
      comments: fn _ -> {:ok, []} end,
      comment: fn _, _ -> :ok end
    ]
  end

  defp resolver(nodes) do
    fn "50", _ ->
      Tracker.resolve_ticket_pull_request("50",
        token: "fixture",
        request_fun: fn request ->
          assert request.caller == "command_override_merged_pr"
          assert request.body["query"] =~ "repository { nameWithOwner }"
          response(false, nodes)
        end
      )
    end
  end

  defp stale_cache do
    key = ResourceStore.key(:branch_pull_request, "owner", "repo", "50")

    ResourceStore.put_resource(
      key,
      %{"state" => "closed", "number" => 60, "merged_at" => DateTime.utc_now() |> DateTime.add(-172_800) |> DateTime.to_iso8601(), "merged" => true, "merge_commit_sha" => "merged-days-ago"},
      source: :webhook
    )

    [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)
    :ets.insert(ResourceStore.Table, {key, %{entry | fetched_at_ms: System.system_time(:millisecond) - 172_800_000}})
  end

  defp node(repo, number, sha) do
    %{"number" => number, "repository" => %{"nameWithOwner" => repo}, "mergedAt" => DateTime.utc_now() |> DateTime.add(-172_800) |> DateTime.to_iso8601(), "mergeCommit" => %{"oid" => sha}}
  end

  defp response(truncated?, nodes \\ [node("owner/repo", 60, "merged-days-ago")]) do
    {:ok,
     %{status: 200, body: %{"data" => %{"repository" => %{"issue" => %{"state" => "CLOSED", "closedByPullRequestsReferences" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => truncated?}}}}}}}}
  end
end
