defmodule Aiur.AgentRunner.ReworkHandoffTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner.ReworkHandoff
  alias Aiur.AgentRunner.TurnLoop
  alias Aiur.Codex.CodingAgent, as: CodexAgent
  alias Aiur.Workspace.Provisioner

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(queue_depth \\ 0), do: GenServer.start_link(__MODULE__, queue_depth)
    @impl true
    def init(queue_depth), do: {:ok, queue_depth}
    def handle_call({:control_capabilities, _identifier}, _from, depth), do: {:reply, {:ok, %{queue_depth: depth}}, depth}
    @impl true
    def handle_call({:claim_next_queue_item, _identifier}, _from, state), do: {:reply, :empty, state}
    def handle_call({:consume_delivered_queue_items, _identifier}, _from, state), do: {:reply, :ok, state}
    def handle_call({:restore_delivered_queue_items, _identifier}, _from, state), do: {:reply, :ok, state}
    def handle_call({:fail_delivered_queue_items, _identifier, _reason}, _from, state), do: {:reply, :ok, state}
  end

  test "rework continues when the dispatch head is unknown, PR lookup fails, or the head is unchanged" do
    issue = %Aiur.Issue{identifier: "rework-no-evidence", state: "rework"}
    {:ok, orchestrator} = FakeOrchestrator.start_link()
    context = %{orchestrator: orchestrator, opts: [rework_head_sha: :pending]}

    assert :continued = ReworkHandoff.after_turn(issue, context, fn -> :continued end)

    context = %{context | opts: [rework_head_sha: "known", open_pr_fetcher: fn _ -> {:error, :github_budget_hold} end]}
    assert :continued = ReworkHandoff.after_turn(issue, context, fn -> :continued end)

    context = %{context | opts: [rework_head_sha: "known", open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "known"}}} end]}
    assert :continued = ReworkHandoff.after_turn(issue, context, fn -> :continued end)
  end

  test "a moved rework head with open review findings continues instead of handing back unchecked" do
    issue = %Aiur.Issue{identifier: "rework-findings", state: "rework"}
    {:ok, orchestrator} = FakeOrchestrator.start_link()
    review = %{"state" => "CHANGES_REQUESTED", "body" => "1. lib/a.ex:3 fix it", "commit_id" => "old", "submitted_at" => "t", "id" => 1, "user" => %{"login" => "r"}, authoritative: true}

    opts = [
      rework_head_sha: "old",
      open_pr_fetcher: fn _ -> {:ok, %{"number" => 7, "head" => %{"sha" => "new"}}} end,
      reviews_fetcher: fn 7 -> {:ok, [review]} end
    ]

    assert :continued = ReworkHandoff.after_turn(issue, %{orchestrator: orchestrator, opts: opts}, fn -> :continued end)
  end

  test "automatic rework handoff refuses a PR body whose Tested head is stale" do
    issue = %Aiur.Issue{identifier: "stale-evidence", state: "rework"}
    {:ok, orchestrator} = FakeOrchestrator.start_link()
    head = String.duplicate("b", 40)
    stale = String.duplicate("a", 40)
    body = "## Local tests\n\nPolicy: partial\nTested head: #{stale}\nBase: main @ #{String.duplicate("c", 40)}\nSelection: focused\n- `mix test` -> passed\n"

    result =
      ReworkHandoff.after_turn(
        issue,
        %{
          orchestrator: orchestrator,
          workspace: nil,
          opts: [
            rework_head_sha: "old-head",
            open_pr_fetcher: fn _ -> {:ok, %{"number" => 18, "body" => body, "head" => %{"sha" => head}}} end,
            reviews_fetcher: fn _ -> {:ok, []} end,
            commit_ci_status_fetcher: fn _ -> {:ok, %{check_runs: [], commit_status: %{"state" => "success"}}} end
          ]
        },
        fn -> :continued end
      )

    assert {:error, {:rework_handoff_evidence_refused, :stale_pr_body_evidence, message}} = result
    assert message =~ "Tested head #{stale} does not match PR head #{head}"
  end

  test "automatic handoff refuses a newer trusted blocking PR comment without a later commit" do
    issue = %Aiur.Issue{identifier: "comment-rework", state: "rework"}
    {:ok, orchestrator} = FakeOrchestrator.start_link()
    head = String.duplicate("b", 40)
    body = "## Local tests\n\nPolicy: partial\nTested head: #{head}\nBase: main @ #{String.duplicate("c", 40)}\nSelection: focused\n- `mix test` -> passed\n"
    comment = %{"body" => "Blocking: fix the failing tests before merge", "updated_at" => "2999-01-01T00:00:00Z", "created_at" => "2999-01-01T00:00:00Z", authoritative: true}

    result =
      ReworkHandoff.after_turn(
        issue,
        %{
          orchestrator: orchestrator,
          workspace: nil,
          opts: [
            rework_head_sha: "old-head",
            open_pr_fetcher: fn _ -> {:ok, %{"number" => 19, "body" => body, "head" => %{"sha" => head}}} end,
            reviews_fetcher: fn _ -> {:ok, []} end,
            pr_issue_comments_fetcher: fn 19 -> {:ok, [comment]} end,
            commit_ci_status_fetcher: fn _ -> {:ok, %{check_runs: [], commit_status: %{"state" => "success"}}} end
          ]
        },
        fn -> :continued end
      )

    assert {:error, {:rework_handoff_evidence_refused, :rework_findings_unaddressed, message}} = result
    assert message =~ "no new non-merge commit has been pushed after it"
    assert message =~ "Blocking: fix the failing tests before merge"
  end

  test "automatic handoff checks a trusted blocking PR comment that has only created_at" do
    issue = %Aiur.Issue{identifier: "comment-created-at", state: "rework"}
    {:ok, orchestrator} = FakeOrchestrator.start_link()
    head = String.duplicate("d", 40)
    body = "## Local tests\n\nPolicy: partial\nTested head: #{head}\nBase: main @ #{String.duplicate("c", 40)}\nSelection: focused\n- " <> "`mix test`" <> " -> passed\n"
    comment = %{"body" => "Blocking: fix the failing tests before merge", "created_at" => "2999-01-01T00:00:00Z", authoritative: true}

    result =
      ReworkHandoff.after_turn(
        issue,
        %{
          orchestrator: orchestrator,
          workspace: nil,
          opts: [
            rework_head_sha: "old-head",
            open_pr_fetcher: fn _ -> {:ok, %{"number" => 20, "body" => body, "head" => %{"sha" => head}}} end,
            reviews_fetcher: fn _ -> {:ok, []} end,
            pr_issue_comments_fetcher: fn 20 -> {:ok, [comment]} end,
            commit_ci_status_fetcher: fn _ -> {:ok, %{check_runs: [], commit_status: %{"state" => "success"}}} end
          ]
        },
        fn -> :continued end
      )

    assert {:error, {:rework_handoff_evidence_refused, :rework_findings_unaddressed, message}} = result
    assert message =~ "no new non-merge commit has been pushed after it"
  end

  test "rework continues to consume queued operator input before handing off" do
    issue = %Aiur.Issue{identifier: "rework-queued", state: "rework"}
    {:ok, orchestrator} = FakeOrchestrator.start_link(1)
    context = %{orchestrator: orchestrator, opts: [rework_head_sha: "old", open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "new"}}} end]}

    assert :continued = ReworkHandoff.after_turn(issue, context, fn -> :continued end)
  end

  test "ci-wait never starts a continuation even if configured as active" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "rework", "ci-wait"]
    )

    Aiur.WorkflowStore.force_reload()
    issue = %Aiur.Issue{id: "ci-wait", identifier: "ci-wait", state: "rework"}
    refreshed = %{issue | state: "ci-wait"}

    assert {:done, ^refreshed} =
             TurnLoop.continue_with_issue?(issue, fn ["ci-wait"] -> {:ok, [refreshed]} end)
  end

  test "a pushed rework head with completed failing CI hands off for review instead of retrying" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "rework"]
    )

    Aiur.WorkflowStore.force_reload()
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    root = Aiur.TestSupport.tmp_root!("rework-handoff")
    workspace = Path.join(root, "ws")
    File.mkdir_p!(workspace)
    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)
    {:ok, orchestrator} = FakeOrchestrator.start_link()
    {:ok, turns} = Agent.start_link(fn -> 0 end)
    identifier = "614309"
    issue = %Aiur.Issue{id: "gid-#{identifier}", identifier: identifier, state: "rework", labels: ["agent:rework"]}

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    assert {:completed, %{state: "human-review"}} =
             TurnLoop.run_turns(
               %{backend: "claude", workspace: workspace, worker_host: nil},
               workspace,
               issue,
               nil,
               [
                 resumed: true,
                 run_turn: fn _session, _prompt, _issue, _opts ->
                   Agent.update(turns, &(&1 + 1))
                   {:ok, %{session_id: "productive-rework"}}
                 end,
                 workspace_probe: fn _workspace, _worker_host -> {:ok, "workspace"} end,
                 rework_head_sha: "reviewed-head",
                 open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "fixed-head"}}} end,
                 commit_ci_status_fetcher: fn _ -> {:ok, %{check_runs: [], commit_status: %{"state" => "failure"}}} end
               ],
               fn _ids -> {:ok, [issue]} end,
               orchestrator,
               nil,
               1,
               nil
             )

    assert Agent.get(turns, & &1) == 1
    assert_receive {:memory_tracker_state_update, ^identifier, "human-review"}, 1000
  end

  test "a rework turn ending with final message and idle releases the runner after one turn" do
    root = Aiur.TestSupport.tmp_root!("rework-idle-handoff")
    workspace = Path.join(root, "ws")
    trace = Path.join(root, "codex.trace")
    binary = Path.join(root, "fake-codex")
    File.mkdir_p!(workspace)
    File.write!(binary, codex_idle_script(trace))
    File.chmod!(binary, 0o755)

    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "rework"],
      workspace_root: root,
      agent_kind: "codex",
      command: "#{binary} app-server",
      agent_turn_timeout_ms: 1_000
    )

    Aiur.WorkflowStore.force_reload()
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)
    {:ok, orchestrator} = FakeOrchestrator.start_link()
    issue = %Aiur.Issue{identifier: "rework-idle", state: "rework", labels: ["agent:rework"]}
    {:ok, session} = CodexAgent.start_session(workspace)
    session = Map.put(session, :backend, "codex")

    on_exit(fn ->
      CodexAgent.stop_session(session)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    assert {:ok, _turn_session} = CodexAgent.run_turn(session, "final fix prompt", issue)

    assert {:completed, %{state: "human-review"}} =
             ReworkHandoff.after_turn(
               issue,
               %{
                 workspace: workspace,
                 worker_host: nil,
                 orchestrator: orchestrator,
                 opts: [
                   rework_head_sha: "old-head",
                   open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "new-head"}}} end,
                   commit_ci_status_fetcher: fn _ -> {:ok, %{check_runs: [], commit_status: %{"state" => "success"}}} end
                 ]
               },
               fn -> :continued end
             )

    assert_receive {:memory_tracker_state_update, "rework-idle", "human-review"}, 1000
    trace_text = File.read!(trace)
    assert trace_text =~ "FINAL_MESSAGE\nIDLE\n"
    assert length(String.split(trace_text, "FINAL_MESSAGE")) == 2
  end

  defp codex_idle_script(trace) do
    """
    #!/bin/sh
    trace_file="#{trace}"
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"initialized"'*) ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"rework-idle-thread"}}}' ;;
        *'"method":"turn/start"'*)
          request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          printf '{"id":%s,"result":{"turn":{"id":"rework-idle-turn"}}}\\n' "$request_id"
          printf '%s\\n' '{"method":"turn/started","params":{"turn":{"id":"rework-idle-turn","status":"inProgress"}}}'
          printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"finished fix"}}}'
          printf 'FINAL_MESSAGE\\n' >> "$trace_file"
          printf '%s\\n' '{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
          printf 'IDLE\\n' >> "$trace_file"
          ;;
      esac
    done
    """
  end
end
