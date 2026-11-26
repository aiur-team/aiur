defmodule Aiur.Orchestrator.CiLifecycle.OwnerlessApprovedPassTest do
  # #5902 / #6117: an approved green PR whose ticket has no live agent must stay in
  # ci-wait, so the claim reconciler has nothing to release and the landing watcher enqueues it.
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.LandingWatch
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.StartupClaimReconciler
  alias Aiur.OrchestratorDeactivateSupport.CIWatcherGitHubClient

  import Aiur.OrchestratorDeactivateSupport

  @ticket "17"
  @head "green-head"
  @green %{"id" => 60, "name" => "ci gate", "status" => "completed", "conclusion" => "success", "check_suite" => %{"id" => 101}}

  setup do
    previous = for key <- [:github_client_module, :ci_watcher_recipient, :ci_approval_store_path], into: %{}, do: {key, Application.get_env(:aiur, key)}
    store_path = Aiur.TestSupport.tmp_root!("aiur_ci_approvals") <> ".json"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent",
      tracker_active_states: ["todo", "in-progress", "rework", "merging"],
      tracker_terminal_states: ["done", "cancelled", "canceled"]
    )

    Application.put_env(:aiur, :github_client_module, CIWatcherGitHubClient)
    Application.put_env(:aiur, :ci_watcher_recipient, self())
    Application.put_env(:aiur, :ci_approval_store_path, store_path)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore_application_env(key, value) end)
      File.rm(store_path)
    end)

    :ok
  end

  test "an ownerless approved green ci-wait ticket is not flapped over repeated poll and reconcile ticks" do
    {_state, writes, ticket_state} = run_ticks(6)

    assert writes == []
    assert ticket_state == "ci-wait"
  end

  test "the landing watcher enqueues the approved PR once the ticks settle" do
    {state, _writes, ticket_state} = run_ticks(3)

    assert :ok = LandingWatch.process(approved_observation(), landing_opts(ticket_state))
    assert_received {:enqueued, @head}
    assert get_in(state.ci_lifecycle, [:approved_heads, @ticket]) == @head
  end

  # One tick = one CI poll plus one claim-reconciler pass against the tracker state the
  # previous tick left behind, which is the loop that flapped in production.
  defp run_ticks(count) do
    Enum.reduce(1..count, {empty_orchestrator_state(), [], "ci-wait"}, fn _tick, {state, writes, ticket_state} ->
      issue = %Issue{id: @ticket, identifier: @ticket, state: ticket_state, title: "Approved green PR"}

      state =
        CiLifecycle.poll_github_ci(%{state | last_ci_poll_started_at_ms: nil},
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, Enum.filter([issue], &(&1.state in ["ci-wait", "human-review"]))} end,
          ci_poller: fn [@ticket], _opts -> {:ok, %{results: [approved_green_result()], errors: []}} end
        )

      poll_writes = drain_writes([])
      polled_state = List.last(poll_writes, ticket_state)
      marker = [read_boot_marker_fun: fn -> {:ok, Aiur.Boot.run_id()} end]
      {state, _issues} = StartupClaimReconciler.reconcile(state, [%{issue | state: polled_state}], marker)
      release_writes = drain_writes([])
      {state, writes ++ poll_writes ++ release_writes, List.last(release_writes, polled_state)}
    end)
  end

  defp drain_writes(acc) do
    receive do
      {:ci_watcher_update, @ticket, written} -> drain_writes(acc ++ [written])
    after
      0 -> acc
    end
  end

  defp approved_green_result do
    %{
      target: @ticket,
      decision: :passed,
      head_sha: @head,
      pr_number: 17,
      draft?: false,
      reviewed_head?: true,
      review_decision: "APPROVED",
      approved_review_head_sha: @head,
      mergeable: "MERGEABLE",
      merge_queue_entry: nil,
      auto_merge_request: nil
    }
  end

  defp landing_opts(ticket_state) do
    parent = self()
    path = Path.join(Aiur.TestSupport.tmp_root!("landing_watch"), "journal.json")

    [
      approved_fun: fn _, _ -> {:ok, true} end,
      required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
      ci_status_fun: fn _, _ -> {:ok, %{check_runs: [@green], commit_status: %{"state" => "success", "statuses" => []}}} end,
      revalidate_fun: fn 17, _, _ -> :ok end,
      attribution_fun: fn _ -> {:ok, :clean} end,
      ticket_state_fun: fn @ticket, _ -> {:ok, ticket_state} end,
      alert_emitter: fn _topic, _details -> :ok end,
      enqueue_fun: fn pr ->
        send(parent, {:enqueued, pr.head})
        {:ok, "entry-1"}
      end,
      journal_path: path
    ]
  end

  defp approved_observation do
    %{
      number: 17,
      node_id: "PR_node",
      head: @head,
      draft?: false,
      review_decision: "APPROVED",
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/17-work"}},
      raw: %{"reviewDecision" => "APPROVED", "headRefOid" => @head, "isDraft" => false, "reviews" => %{"nodes" => [%{"commit" => %{"oid" => @head}}]}}
    }
  end
end
