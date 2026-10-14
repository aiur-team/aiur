defmodule Aiur.Orchestrator.CiRecoveryTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO
  import Aiur.OrchestratorDeactivateSupport
  alias Aiur.AlertLedger
  alias Aiur.CI.FailureDigest
  alias Aiur.ControlCLI.CiWait
  alias Aiur.Events.GithubCIPoller.Recovery, as: CiRecovery
  alias Aiur.GitHub.CIRecoveryStore, as: CiRecoveryStore
  alias Aiur.GitHub.ResourceStore
  alias Aiur.{Issue, JsonStore}
  alias Aiur.Orchestrator.{CiLifecycle, StatusReport}
  alias Aiur.Orchestrator.StatusReport.SnapshotPayload
  alias Aiur.OrchestratorDeactivateSupport.CIWatcherGitHubClient

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.clear(:ci_failure_digest, "owner", "repo")
    ResourceStore.clear(:flake_issues, "owner", "repo")
    root = Aiur.TestSupport.tmp_root!("ci_recovery")
    File.mkdir_p!(root)
    path = Path.join(root, "recovery.json")

    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             attempt: 1,
             requests: [],
             behind: false,
             queued: false,
             changed: ["src/lib/other.ex"],
             actions_get_status: 200,
             actions_post_status: 202,
             graphql_error: false,
             head: "head-1",
             advance: true,
             extra: [],
             known: false,
             stale_evidence: false,
             passed: false
           }
         end}
      )

    request = fn req ->
      state = Agent.get_and_update(agent, fn state -> {state, %{state | requests: state.requests ++ [req]}} end)
      response(req, state, agent, path)
    end

    issue = %Issue{id: "3864", identifier: "3864", state: "ci-wait"}
    result = %{target: "3864", pr_number: 42, head_sha: "head-1", decision: :failed, failures: [%{name: "test"}]}

    opts = [
      request_fun: request,
      ci_recovery_path: path,
      ledger_paths: [path <> ".alerts"],
      alert_emitter: fn topic, details ->
        send(self(), {:attention, topic, details})
        AlertLedger.append(%{"topic" => topic, "needs_attention" => true}, ledger_path: path <> ".alerts")
      end
    ]

    on_exit(fn ->
      ResourceStore.clear(:ci_failure_digest, "owner", "repo")
      ResourceStore.clear(:flake_issues, "owner", "repo")
    end)

    %{issue: issue, result: result, opts: opts, agent: agent, path: path}
  end

  test "unrelated test gets exactly one failed-job rerun, persisted across observations", ctx do
    assert %{decision: :pending, recovery: "rerun_requested"} = recover(ctx)
    assert %{decision: :failed} = recover(ctx)
    assert %{decision: :failed} = recover(ctx)
    assert writes(ctx) == [{:post, "/actions/runs/99/rerun-failed-jobs"}]
    assert {:ok, %{"heads" => %{"head-1" => %{"runs" => [%{"id" => 99, "attempt" => 1, "conclusion" => "failure"}]}}}} = CiRecoveryStore.read("3864", 42, ctx.opts)
    refute_received {:attention, _, _}
  end

  test "unknown or independent check failures never rerun", ctx do
    Agent.update(ctx.agent, &%{&1 | extra: [%{"annotation_level" => "failure", "message" => "coverage too low"}]})
    assert %{decision: :failed} = recover(ctx)
    assert writes(ctx) == []
    refute Enum.any?(requests(ctx), &(&1.url == "https://api.github.com/graphql"))
  end

  test "a changed failing test is delivered to rework", ctx do
    Agent.update(ctx.agent, &%{&1 | changed: ["src/test/untouched_test.exs"]})
    assert %{decision: :failed} = recover(ctx)
    assert writes(ctx) == []
  end

  test "a known flake reruns even when its file is changed", ctx do
    Agent.update(ctx.agent, &%{&1 | known: true, changed: ["src/test/untouched_test.exs"]})
    assert %{decision: :pending, recovery: "rerun_requested"} = recover(ctx)
    assert length(writes(ctx)) == 1
  end

  for {method, status} <- [{:get, 403}, {:get, 404}, {:post, 403}, {:post, 404}] do
    key = if method == :get, do: :actions_get_status, else: :actions_post_status
    reason = if method == :get, do: "rerun_unavailable", else: "rerun_failed"
    expected_writes = if method == :post, do: [{:post, "/actions/runs/99/rerun-failed-jobs"}], else: []

    test "Actions #{method} #{status} falls back to rework once without repeated requests", ctx do
      status = unquote(status)
      key = unquote(key)
      reason = unquote(reason)
      Agent.update(ctx.agent, &Map.put(&1, key, status))
      assert %{decision: :failed} = result = recover(ctx)
      refute CiRecovery.attention_hold?(result)
      assert_received {:attention, topic, details}
      assert topic == "ticket.3864.pr.ci_recovery." <> reason
      assert details[:message] =~ "UntouchedTest :: fails"
      first_requests = requests(ctx)
      assert %{decision: :failed} = recover(ctx)
      assert %{decision: :failed} = recover(ctx)
      assert requests(ctx) == first_requests
      refute_received {:attention, _, _}
      assert writes(ctx) == unquote(expected_writes)
    end
  end

  test "an approved BEHIND PR with a changed failing test reaches rework without updating its base", ctx do
    setup_lifecycle(ctx)
    Agent.update(ctx.agent, &%{&1 | behind: true, changed: ["src/test/untouched_test.exs"]})
    state = lifecycle_poll(empty_orchestrator_state(), ctx, ctx.issue)
    assert_received {:ci_watcher_update, "3864", "rework"}
    assert state.ci_lifecycle.poll_cache["3864"].decision == :failed
    assert writes(ctx) == []
  end

  test "Actions permission fallback reaches the lifecycle rework handoff", ctx do
    setup_lifecycle(ctx)
    Agent.update(ctx.agent, &%{&1 | actions_post_status: 403})
    state = lifecycle_poll(empty_orchestrator_state(), ctx, ctx.issue)
    assert_received {:ci_watcher_update, "3864", "rework"}
    assert_received {:attention, "ticket.3864.pr.ci_recovery.rerun_failed", _}
    assert state.ci_lifecycle.poll_cache["3864"].decision == :failed
    refute CiRecovery.attention_hold?(state.ci_lifecycle.poll_cache["3864"])
    first_requests = requests(ctx)
    state = lifecycle_poll(state, ctx, %{ctx.issue | updated_at: DateTime.from_unix!(2)})
    assert requests(ctx) == first_requests
    refute_received {:attention, _, _}
    lifecycle_poll(state, ctx, %{ctx.issue | updated_at: DateTime.from_unix!(3)})
    assert_received {:attention, "ticket.3864.pr.ci_recovery.loop", details}
    assert details[:message] =~ "UntouchedTest :: fails"
    assert requests(ctx) == first_requests
  end

  test "unavailable Actions evidence holds without repeating reads or attention", ctx do
    Agent.update(ctx.agent, &%{&1 | actions_get_status: 500})
    assert %{decision: :pending, recovery: "rerun_unavailable"} = recover(ctx)
    assert_received {:attention, "ticket.3864.pr.ci_recovery.rerun_unavailable", _}
    first_requests = requests(ctx)
    assert %{decision: :pending, recovery: "rerun_unavailable"} = recover(ctx)
    assert requests(ctx) == first_requests
    assert writes(ctx) == []
    refute_received {:attention, _, _}
  end

  test "persisted observation holds issue no more requests until a new head", ctx do
    Agent.update(ctx.agent, &%{&1 | graphql_error: true})
    assert %{decision: :pending, recovery: "observation_unavailable"} = recover(ctx)
    assert_received {:attention, "ticket.3864.pr.ci_recovery.observation_unavailable", _}
    first_requests = requests(ctx)
    assert %{decision: :pending, recovery: "observation_unavailable"} = recover(ctx)
    assert requests(ctx) == first_requests
    refute_received {:attention, _, _}
    Agent.update(ctx.agent, &%{&1 | graphql_error: false, head: "head-2"})
    assert %{decision: :pending, recovery: "rerun_requested"} = recover(%{ctx | result: %{ctx.result | head_sha: "head-2"}})
    assert length(requests(ctx)) > length(first_requests)
  end

  test "persisted digest evidence holds are returned before rebuilding the digest", ctx do
    digest = fn _, _ ->
      send(self(), :digest_built)
      {:error, :digest_unavailable}
    end

    ctx = %{ctx | opts: Keyword.put(ctx.opts, :ci_failure_digest, digest)}
    assert %{decision: :pending, recovery: "evidence_unavailable"} = recover(ctx)
    assert_received :digest_built
    assert_received {:attention, "ticket.3864.pr.ci_recovery.evidence_unavailable", _}
    assert %{decision: :pending, recovery: "evidence_unavailable"} = recover(ctx)
    refute_received :digest_built
    refute_received {:attention, _, _}
    assert requests(ctx) == []
    assert :ok = CiRecovery.record_pass(ctx.issue, ctx.result, ctx.opts)
    assert %{decision: :pending, recovery: "evidence_unavailable"} = recover(ctx)
    assert_received :digest_built
  end

  test "queued PRs are left alone", ctx do
    Agent.update(ctx.agent, &%{&1 | queued: true, behind: true})
    assert %{decision: :pending, recovery: "merge_queue"} = recover(ctx)
    assert writes(ctx) == []
    refute_received {:attention, _, _}
  end

  test "three failed handoffs raise one attention naming tests, then hold", ctx do
    for n <- 1..3 do
      result = Map.put(ctx.result, :ci_failure_digest, %FailureDigest{tests: [%{identity: "UntouchedTest :: fails"}]})
      assert :ok = CiRecovery.record_failure(%{ctx.issue | updated_at: DateTime.from_unix!(n)}, result, ctx.opts)
    end

    assert_received {:attention, "ticket.3864.pr.ci_recovery.loop", details}
    assert details[:message] =~ "3 failed CI/rework cycles"
    assert details[:message] =~ "UntouchedTest :: fails"
    first_requests = requests(ctx)
    assert %{decision: :pending, recovery: "loop"} = recover(ctx)
    assert %{decision: :pending, recovery: "loop"} = recover(ctx)
    assert requests(ctx) == first_requests
    refute_received {:attention, "ticket.3864.pr.ci_recovery.loop", _}
    assert writes(ctx) == []
    assert :ok = CiRecovery.record_pass(ctx.issue, ctx.result, ctx.opts)
    assert %{decision: :pending, recovery: "rerun_requested"} = recover(ctx)
  end

  test "corrupt journal fails closed before GitHub writes", ctx do
    File.write!(ctx.path, "invalid json")
    assert %{decision: :pending, recovery: "evidence_unavailable"} = recover(ctx)

    for entry <- [%{"pr" => 42}, %{"pr" => 42, "cycles" => 0, "heads" => %{"head-1" => %{"runs" => []}}}] do
      content = Jason.encode!(%{"3864" => entry})
      File.write!(ctx.path, content)
      assert %{decision: :pending, recovery: "evidence_unavailable"} = recover(ctx)
      assert writes(ctx) == []
    end

    assert_received {:attention, "ticket.3864.pr.ci_recovery.journal_failed", _}
    refute_received {:attention, "ticket.3864.pr.ci_recovery.journal_failed", _}
  end

  test "failed journal writes return errors and raise Executor attention", ctx do
    File.mkdir_p!(ctx.path)
    assert {:error, _} = CiRecovery.record_pass(ctx.issue, ctx.result, ctx.opts)
    assert_received {:attention, "ticket.3864.pr.ci_recovery.journal_failed", _}
    assert {:error, _} = CiRecovery.record_failure(ctx.issue, ctx.result, ctx.opts)
    refute_received {:attention, "ticket.3864.pr.ci_recovery.journal_failed", _}
    assert writes(ctx) == []
  end

  test "rerun waiting does not deliver the old failure; ten-minute delay escalates", ctx do
    Agent.update(ctx.agent, &%{&1 | advance: false})
    first_opts = Keyword.put(ctx.opts, :ci_recovery_now, 1000)
    CiRecovery.recover(ctx.issue, ctx.result, first_opts)
    assert %{decision: :pending, recovery: "rerun_pending"} = CiRecovery.recover(ctx.issue, ctx.result, Keyword.put(ctx.opts, :ci_recovery_now, 1100))
    refute_received {:attention, "ticket.3864.pr.ci_recovery.rerun_stuck", _}
    assert %{recovery: "rerun_stuck"} = CiRecovery.recover(ctx.issue, ctx.result, Keyword.put(ctx.opts, :ci_recovery_now, 1600))
    assert_received {:attention, "ticket.3864.pr.ci_recovery.rerun_stuck", _}
    first_requests = requests(ctx)
    assert %{recovery: "rerun_stuck"} = recover(ctx)
    assert requests(ctx) == first_requests
    refute_received {:attention, _, _}
  end

  test "lifecycle holds the rerun then hands a full current-head pass to the agent", ctx do
    setup_lifecycle(ctx)

    poll = fn state, result ->
      CiLifecycle.poll_github_ci(past_ci_cadence(state), ctx.opts ++ [ci_issue_fetcher: fn _ -> {:ok, [ctx.issue]} end, ci_poller: fn _, _ -> {:ok, %{results: [result], errors: []}} end])
    end

    state = poll.(empty_orchestrator_state(), ctx.result)
    refute_received {:ci_watcher_update, "3864", "rework"}
    assert state.ci_lifecycle.poll_cache["3864"].recovery == "rerun_requested"
    snapshot = state |> StatusReport.snapshot_input() |> SnapshotPayload.snapshot_payload()
    assert capture_io(fn -> CiWait.print(snapshot) end) =~ "CI WAIT 3864 PR #42: rerun_requested"
    assert state.running == %{}
    assert :ok = CiRecovery.record_failure(ctx.issue, ctx.result, ctx.opts)
    state = poll.(state, %{ctx.result | decision: :passed, failures: []})
    assert state |> StatusReport.snapshot_input() |> SnapshotPayload.snapshot_payload() |> Map.get(:ci_wait) == []
    assert_received {:ci_watcher_update, "3864", "in-progress"}
    assert {:ok, %{"cycles" => 0, "attentions" => []}} = CiRecoveryStore.read("3864", 42, ctx.opts)
    assert length(writes(ctx)) == 1
  end

  test "status names skipped draft checks" do
    output = capture_io(fn -> CiWait.print(%{ci_wait: [%{identifier: "4316", pr_number: 17, decision: :pending, pending_reason: :draft_pull_request, failures: []}]}) end)
    assert output =~ "CI WAIT 4316 PR #17: draft_pr"
  end

  test "a cancelled verdict stays pending and raises one neutral skip attention", ctx do
    setup_lifecycle(ctx)
    cancelled = Map.merge(ctx.result, %{decision: :pending, pending_reason: :ci_cancelled, failures: []})
    state = lifecycle_poll(empty_orchestrator_state(), %{ctx | result: cancelled}, ctx.issue)
    assert state.ci_lifecycle.poll_cache["3864"].recovery == "rerun_skipped"
    assert_received {:attention, "ticket.3864.pr.ci_recovery.rerun_skipped", details}
    assert details[:message] =~ "cancelled_run"
    refute Enum.any?(requests(ctx), &(&1.method == :post))

    state = lifecycle_poll(state, %{ctx | result: cancelled}, ctx.issue)
    assert state.ci_lifecycle.poll_cache["3864"].recovery == "rerun_skipped"
    refute_received {:attention, _, _}
  end

  test "scheduled CI polls get distinct rerun admission ids", ctx do
    setup_lifecycle(ctx)
    recipient = self()

    opts =
      ctx.opts ++
        [
          ci_issue_fetcher: fn _states -> {:ok, [ctx.issue]} end,
          ci_poller: fn _targets, poll_opts ->
            send(recipient, {:ci_recovery_poll_id, Keyword.fetch!(poll_opts, :ci_recovery_poll_id)})
            {:ok, %{results: [], errors: []}}
          end
        ]

    CiLifecycle.start_poll(empty_orchestrator_state(), &Function.identity/1, opts)
    CiLifecycle.start_poll(empty_orchestrator_state(), &Function.identity/1, opts)
    assert_receive {:ci_recovery_poll_id, first}, 1_000
    assert_receive {:ci_recovery_poll_id, second}, 1_000
    assert is_reference(first)
    assert is_reference(second)
    refute first == second
  end

  test "pending CI observations retain recovery and suppress fallback wakes", ctx do
    setup_lifecycle(ctx)
    Agent.update(ctx.agent, &%{&1 | advance: false})
    state = lifecycle_poll(empty_orchestrator_state(), ctx, ctx.issue)
    state = lifecycle_poll(state, %{ctx | result: %{ctx.result | decision: :pending, failures: []}}, ctx.issue)
    assert state.ci_lifecycle.poll_cache["3864"].recovery == "rerun_pending"
    agent = control_test_agent(self())
    on_exit(fn -> if Process.alive?(agent), do: Process.exit(agent, :kill) end)
    parked = human_review_running_state("3864", agent).running["3864"]
    parked = %{parked | issue: ctx.issue, control: confirmed_control(:paused)} |> Map.put(:paused_reason, :ci_wait)
    state = %{state | running: %{"3864" => parked}} |> CiLifecycle.arm_ci_wait_rewake(ctx.issue)
    timer = state.ci_lifecycle.rewakes["3864"]
    Process.cancel_timer(timer.timer_ref)
    state = CiLifecycle.handle_ci_wait_rewake(state, "3864", timer.token, issue_fetcher: fn _ -> {:ok, [ctx.issue]} end)
    refute_received {:ci_watcher_update, "3864", "in-progress"}
    assert state.running["3864"].issue.state == "ci-wait"
  end

  test "a completed rerun cannot deliver the prior check-run failures", ctx do
    assert %{recovery: "rerun_requested"} = recover(ctx)
    Agent.update(ctx.agent, &%{&1 | stale_evidence: true})
    assert %{decision: :pending, recovery: "rerun_pending"} = recover(ctx)
    Agent.update(ctx.agent, &%{&1 | stale_evidence: false, passed: true})
    assert %{decision: :pending, recovery: "rerun_pending"} = recover(ctx)
    Agent.update(ctx.agent, &%{&1 | passed: false, attempt: 3})
    assert %{decision: :failed} = recover(ctx)
  end

  test "lifecycle retains worker errors without crashing or handing off", ctx do
    setup_lifecycle(ctx)
    opts = Keyword.put(ctx.opts, :ci_recovery, fn _, _, _ -> {:error, :tracker_task_timeout} end)
    state = lifecycle_poll(empty_orchestrator_state(), %{ctx | opts: opts}, ctx.issue)
    assert state.ci_lifecycle.poll_cache["3864"].recovery == "worker_failed"
    assert_received {:attention, "ticket.3864.pr.ci_recovery.worker_failed", details}
    assert details[:message] =~ "tracker_task_timeout"
    refute_received {:ci_watcher_update, "3864", "rework"}
    assert CiRecovery.attention_hold?(state.ci_lifecycle.poll_cache["3864"])
  end

  test "status lists held CI even without a running agent", ctx do
    output =
      capture_io(fn -> CiWait.print(%{ci_wait: [%{identifier: "3864", pr_number: 42, recovery: "loop", failures: ctx.result.failures}]}) end)

    assert output == "CI WAIT 3864 PR #42: loop (test)\n"
  end

  test "lifecycle counts three same-head rework cycles and keeps the fourth held", ctx do
    setup_lifecycle(ctx)
    Agent.update(ctx.agent, &%{&1 | changed: ["src/test/untouched_test.exs"]})

    state =
      Enum.reduce(1..3, empty_orchestrator_state(), fn n, state ->
        issue = %{ctx.issue | updated_at: DateTime.from_unix!(n)}
        state = lifecycle_poll(state, ctx, issue)
        assert_received {:ci_watcher_update, "3864", "rework"}
        state
      end)

    assert_received {:attention, "ticket.3864.pr.ci_recovery.loop", details}
    assert details[:message] =~ "UntouchedTest :: fails"
    state = lifecycle_poll(state, ctx, %{ctx.issue | updated_at: DateTime.from_unix!(4)})
    refute_received {:ci_watcher_update, "3864", "rework"}
    refute_received {:attention, "ticket.3864.pr.ci_recovery.loop", _}
    assert state.ci_lifecycle.poll_cache["3864"].recovery == "loop"
    agent = control_test_agent(self())
    on_exit(fn -> if Process.alive?(agent), do: Process.exit(agent, :kill) end)
    parked = human_review_running_state("3864", agent).running["3864"]
    parked = %{parked | issue: ctx.issue, control: confirmed_control(:paused)} |> Map.put(:paused_reason, :ci_wait)
    state = %{state | running: %{"3864" => parked}} |> CiLifecycle.arm_ci_wait_rewake(ctx.issue)
    timer = state.ci_lifecycle.rewakes["3864"]
    Process.cancel_timer(timer.timer_ref)
    state = CiLifecycle.handle_ci_wait_rewake(state, "3864", timer.token, issue_fetcher: fn _ -> {:ok, [ctx.issue]} end)
    refute_received {:ci_watcher_update, "3864", "in-progress"}
    assert state.running["3864"].issue.state == "ci-wait"
  end

  defp lifecycle_poll(state, ctx, issue) do
    CiLifecycle.poll_github_ci(past_ci_cadence(state), ctx.opts ++ [ci_issue_fetcher: fn _ -> {:ok, [issue]} end, ci_poller: fn _, _ -> {:ok, %{results: [ctx.result], errors: []}} end])
  end

  # A running Orchestrator can publish the :ci cadence at any moment; these polls are separate ticks (#4360).
  defp past_ci_cadence(state), do: %{state | last_ci_poll_started_at_ms: nil}

  defp setup_lifecycle(ctx) do
    previous = Application.get_env(:aiur, :github_client_module)
    recipient = Application.get_env(:aiur, :ci_watcher_recipient)
    store = Application.get_env(:aiur, :ci_approval_store_path)
    Application.put_env(:aiur, :github_client_module, CIWatcherGitHubClient)
    Application.put_env(:aiur, :ci_watcher_recipient, self())
    Application.put_env(:aiur, :ci_approval_store_path, ctx.path <> ".approvals")

    on_exit(fn ->
      restore_application_env(:github_client_module, previous)
      restore_application_env(:ci_watcher_recipient, recipient)
      restore_application_env(:ci_approval_store_path, store)
    end)
  end

  defp recover(ctx), do: CiRecovery.recover(ctx.issue, ctx.result, ctx.opts)
  defp requests(ctx), do: Agent.get(ctx.agent, & &1.requests)

  defp writes(ctx),
    do:
      requests(ctx)
      |> Enum.reject(&(&1.method == :get or &1.url == "https://api.github.com/graphql"))
      |> Enum.map(&{&1.method, URI.parse(&1.url).path |> String.replace_prefix("/repos/owner/repo", "")})

  defp response(%{method: :post, url: "https://api.github.com/graphql"}, %{graphql_error: true}, _, _), do: {:error, :observation_failed}

  defp response(%{method: :post, url: "https://api.github.com/graphql"}, state, _, _) do
    ok(%{
      "data" => %{
        "repository" => %{
          "pullRequest" => %{
            "state" => "OPEN",
            "headRefOid" => state.head,
            "isDraft" => false,
            "reviewDecision" => "APPROVED",
            "baseRefName" => "main",
            "mergeable" => "MERGEABLE",
            "mergeStateStatus" => if(state.behind, do: "BEHIND", else: "CLEAN"),
            "mergeQueueEntry" => if(state.queued, do: %{"id" => "queued"}, else: nil)
          }
        }
      }
    })
  end

  defp response(%{method: :post, url: url}, state, agent, path) do
    assert {:ok, entries} = JsonStore.read(path)
    assert get_in(entries, ["3864", "heads", state.head, "runs"]) == [%{"id" => 99, "attempt" => 1, "conclusion" => "failure"}]
    assert String.contains?(url, "rerun-failed-jobs")
    if state.actions_post_status == 202 and state.advance, do: Agent.update(agent, &%{&1 | attempt: &1.attempt + 1})
    %{status: state.actions_post_status, body: %{"message" => "Resource not accessible by integration"}} |> then(&{:ok, &1})
  end

  defp response(%{url: url}, state, _, _) do
    cond do
      String.contains?(url, "/check-runs?") ->
        ok(%{"check_runs" => [check_run(state)]})

      String.ends_with?(url, "/status") ->
        ok(%{"statuses" => []})

      String.contains?(url, "/annotations?") ->
        ok([%{"title" => "aiur-test-failure", "annotation_level" => "failure", "message" => "new-failure :: UntouchedTest :: fails", "path" => "src/test/untouched_test.exs"}] ++ state.extra)

      String.contains?(url, "/contents/") ->
        ok(%{"encoding" => "base64", "content" => Base.encode64(if(state.known, do: "UntouchedTest :: fails", else: ""))})

      String.contains?(url, "/issues?") ->
        ok([])

      String.contains?(url, "/files?") ->
        ok(Enum.map(state.changed, &%{"filename" => &1, "status" => "modified"}))

      String.ends_with?(url, "/actions/runs/99") ->
        {:ok, %{status: state.actions_get_status, body: %{"head_sha" => state.head, "run_attempt" => state.attempt, "status" => "completed", "conclusion" => "failure"}}}
    end
  end

  defp check_run(state) do
    %{
      "id" => if(state.stale_evidence, do: 1, else: state.attempt),
      "name" => "test",
      "status" => "completed",
      "conclusion" => if(state.passed, do: "success", else: "failure"),
      "html_url" => "https://github.com/owner/repo/actions/runs/99/job/1"
    }
  end

  defp ok(body), do: {:ok, %{status: 200, body: body, headers: []}}
end
