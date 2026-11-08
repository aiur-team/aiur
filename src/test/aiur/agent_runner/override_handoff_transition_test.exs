defmodule Aiur.AgentRunner.OverrideHandoffTransitionTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner.{ReworkHandoff, ToolExecutor}
  alias Aiur.{Commands, DecisionStore}
  alias Aiur.Orchestrator.ReworkGate

  defmodule CodeHostTracker do
    def code_host, do: __MODULE__
    def fetch_open_pull_request_for_branch(_), do: {:ok, nil}
  end

  defmodule EmptyQueue do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call({:control_capabilities, _}, _from, state), do: {:reply, {:ok, %{queue_depth: 0}}, state}
  end

  setup do
    previous = Application.fetch_env!(:aiur, :tracker_adapters)
    Application.put_env(:aiur, :tracker_adapters, Map.new(previous, fn {kind, _} -> {kind, CodeHostTracker} end))
    on_exit(fn -> Application.put_env(:aiur, :tracker_adapters, previous) end)
    :ok
  end

  test "the worker tool records its verified PR receipt before changing the ticket state" do
    owner = self()
    pr = %{"number" => 77, "draft" => false, "head" => %{"sha" => String.duplicate("b", 40)}}

    recorder = fn "50", "ci-wait", ^pr, "/worker", nil, _ ->
      send(owner, :worker_receipt)
      :ok
    end

    writer = fn _, _ ->
      assert_received :worker_receipt
      :ok
    end

    executor = executor(pr, recorder, writer)
    assert executor.("aiur_set_ticket_state", %{"state" => "ci-wait"})["success"]
  end

  test "the default worker tool journals its real receipt before the state writer" do
    dir = Aiur.TestSupport.tmp_root!("default-worker-receipt")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    store =
      start_supervised!(
        {DecisionStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000, reconcile_delay_ms: 60_000, answer_comment_publisher: fn _ -> :ok end}
      )

    {:ok, %{decision: requested}} = Commands.request(%{source_id: "default-tool", question: "Proceed?", blocking: false}, [ticket: %{identifier: "50"}], store)
    actor = [actor: %{kind: :operator, id: "human"}]
    payload = fn value -> %{expected_version: 1, custom_response: value, rationale: "Correction", idempotency_key: value} end
    {:ok, _} = Commands.answer(requested.decision_id, payload.("original"), actor, store)
    before = String.duplicate("a", 40)
    context = %{pr: %{number: 77, merged?: false, head_sha: before, head_ref: "work"}, worker: :active, capacity: :available}
    {:ok, %{decision: override}} = Commands.override(requested.decision_id, payload.("override"), actor ++ [override_context: context], store)
    {:ok, _} = Commands.record_command_fact(requested.decision_id, :override_prompt_delivered, %{action_id: override.active_action_id, at: DateTime.utc_now()}, server: store)
    {:ok, %{overrides: [%{delivered_at: delivered}]}} = DecisionStore.get(requested.decision_id, store)
    head = String.duplicate("b", 40)
    pr = %{"number" => 77, "draft" => false, "head" => %{"sha" => head}}

    writer = fn "50", "ci-wait" ->
      assert {:ok, %{overrides: [%{evidence: %{worker_reported: true, head_sha: ^head}}]}} = DecisionStore.get(requested.decision_id, store)
      assert {:ok, audit} = DecisionStore.audit_history(requested.decision_id, store)
      assert Enum.any?(audit, &match?(%Aiur.DecisionEvent{type: :override_worker_handoff, data: %{head_sha: ^head}}, &1))
      :ok
    end

    worker =
      ToolExecutor.build(%Aiur.Issue{id: "50", identifier: "50", state: "in-progress"}, "/worker", nil, %{},
        decision_store: store,
        override_handoff_head_reader: fn _, _ -> {:ok, %{head_sha: head, upstream_sha: head, committed_at: DateTime.add(delivered, 1)}} end,
        open_pr_fetcher: fn _ -> {:ok, nil} end,
        ci_wait_pr_fetcher: fn _ -> {:ok, pr} end,
        coordination_runner: fn _, operation, _ -> operation.() end,
        ticket_state_writer: writer
      )

    assert worker.("aiur_set_ticket_state", %{"state" => "ci-wait"})["success"]
  end

  # Future regression guard: draft and ordinary transitions already skipped worker receipts.
  test "draft and non-handoff transitions never attest a worker head" do
    recorder = fn _, _, _, _, _, _ -> flunk("no worker receipt belongs to this transition") end
    draft = executor(%{"number" => 77, "draft" => true}, recorder, fn _, _ -> flunk("draft refused") end)
    refute draft.("aiur_set_ticket_state", %{"state" => "ci-wait"})["success"]
    normal = executor(nil, recorder, fn _, "in-progress" -> :ok end)
    assert normal.("aiur_set_ticket_state", %{"state" => "in-progress"})["success"]
  end

  test "a failed qualifying receipt cannot change the worker's ticket state" do
    recorder = fn _, _, _, _, _, _ -> {:error, {:override_handoff_unconfirmed, "journal unavailable"}} end
    worker = executor(%{"number" => 77, "draft" => false}, recorder, fn _, _ -> flunk("receipt failure must precede the writer") end)
    refute worker.("aiur_set_ticket_state", %{"state" => "human-review"})["success"]
  end

  test "automatic completed-turn handoff attests the already-fetched PR and preserves legacy gate shape" do
    head = String.duplicate("b", 40)
    body = "## Local tests\n\nPolicy: partial\nTested head: #{head}\nBase: main @ #{String.duplicate("c", 40)}\nSelection: focused\n- `mix test` -> passed\n"
    pr = %{"number" => 77, "draft" => false, "body" => body, "head" => %{"sha" => head}}
    fetch = fn _ -> {:ok, pr} end

    opts = [
      pull_request_approval_fetcher: fn _ -> {:ok, {head, nil}} end,
      reviews_fetcher: fn _ -> {:ok, []} end,
      open_pr_fetcher: fetch,
      commit_ci_status_fetcher: fn _ -> {:ok, %{check_runs: [], commit_status: %{"state" => "pending"}}} end
    ]

    assert {:handoff, "ci-wait"} = ReworkGate.completed_agent_handoff("50", "before", opts)
    assert {:handoff, "ci-wait", ^pr} = ReworkGate.completed_agent_handoff("50", "before", Keyword.put(opts, :include_pr, true))
    owner = self()

    recorder = fn "50", "ci-wait", ^pr, nil, nil, _ ->
      send(owner, :automatic_worker_receipt)
      {:error, :receipt_probe}
    end

    opts = opts ++ [rework_head_sha: "before", reviews_fetcher: fn _ -> {:ok, []} end, pr_issue_comments_fetcher: fn _ -> {:ok, []} end, override_handoff_recorder: recorder]
    queue = start_supervised!(EmptyQueue)
    context = %{orchestrator: queue, workspace: nil, worker_host: nil, opts: opts}

    assert {:error, {:rework_handoff_state_write_failed, :receipt_probe}} =
             ReworkHandoff.after_turn(%Aiur.Issue{identifier: "50", state: "rework"}, context, fn -> flunk("completed handoff expected") end)

    assert_received :automatic_worker_receipt
  end

  defp executor(pr, recorder, writer) do
    ToolExecutor.build(%Aiur.Issue{id: "50", identifier: "50", state: "in-progress"}, "/worker", nil, %{},
      open_pr_fetcher: fn _ -> {:ok, nil} end,
      ci_wait_pr_fetcher: fn _ -> {:ok, pr} end,
      coordination_runner: fn _, operation, _ -> operation.() end,
      override_handoff_recorder: recorder,
      ticket_state_writer: writer
    )
  end
end
