Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.ExecutorRequestCLITest do
  use Aiur.DecisionStoreCase, async: false
  import ExUnit.CaptureIO
  alias Aiur.Commands.RequestContent
  alias Aiur.Commands.Routing
  alias Aiur.ControlCLI.ExecutorRequest

  setup %{dir: dir} do
    previous = Application.get_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(dir, "executor"))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :executor_state_dir, previous), else: Application.delete_env(:aiur, :executor_state_dir)
    end)

    store = start_store!(dir)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
    %{store: store}
  end

  defp params do
    [
      question: "Ship the beta?",
      options: ["wait=Wait", "ship=Ship"],
      recommend: "ship",
      executor_id: "requester",
      idempotency_key: "exec-beta",
      ticket: "6410",
      short_summary: "Beta release",
      long_context_markdown: "Release context",
      json: true
    ]
  end

  test "request persists attribution, routes to human and publishes only Executor lifecycle", %{store: store} do
    :ok = Aiur.ExecutorEvents.subscribe("executor.#")
    :ok = Exchange.subscribe("ticket.executor.#")
    output = capture_io(fn -> assert 0 == ExecutorRequest.request(params(), decision_store: store) end)
    result = Jason.decode!(output)
    assert result["status"] == "accepted"
    assert result["source_id"] == "exec-beta"
    assert Map.has_key?(result, "route_state")
    assert result["route_state"] == nil
    assert {:ok, decision} = DecisionStore.get(result["decision_id"], store)
    assert %{kind: :executor, executor_id: "requester", ticket: "6410"} = decision.requester
    assert decision.origin == :executor_cli
    assert decision.ticket.identifier == "executor"
    assert decision.source == %{agent_id: "executor", session_id: "requester", event_id: "exec-beta"}
    assert decision.question == "Ship the beta?"
    assert decision.authority == :human_required
    assert decision.blocking
    assert decision.urgency == :normal
    assert Enum.map(decision.options, & &1.id) == ["ship", "wait"]
    assert decision.recommendation.option_id == "ship"
    assert decision.context.short_summary == "Beta release"
    assert decision.context.long_context_markdown == "Release context"

    router =
      start_supervised!({Routing, name: nil, store: store, roster_fun: fn _ -> %{executors: [%{state: :active}]} end, config: %{enabled: true, ack_ms: 1000, answer_ms: 2000, urgent_factor: 0.5}})

    assert :ok = GenServer.call(router, :sweep)
    assert {:ok, routed} = DecisionStore.get(decision.decision_id, store)
    assert routed.route_state == :with_human
    assert {:ok, history} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.count(history, &(&1.type == :human_needed)) == 1
    assert Enum.find(history, &(&1.type == :human_needed)).data.cause == :executor_originated
    assert {:ok, [event]} = Aiur.ExecutorEvents.replay(["executor.decision.requested"], 0)
    assert event["decision_id"] == decision.decision_id
    refute_received {:event, %{topic: "ticket.executor.agent.decision.requested"}}
  end

  test "retrying an idempotency key returns the same Command", %{store: store} do
    first = capture_io(fn -> assert 0 == ExecutorRequest.request(params(), decision_store: store) end) |> Jason.decode!()
    second = capture_io(fn -> assert 0 == ExecutorRequest.request(params(), decision_store: store) end) |> Jason.decode!()
    assert second["status"] == "duplicate"
    assert second["decision_id"] == first["decision_id"]
  end

  test "distinct retry keys preserve independent Executor attribution and ticket contexts", %{store: store} do
    first = capture_io(fn -> assert 0 == ExecutorRequest.request(params(), decision_store: store) end) |> Jason.decode!()
    other = Keyword.merge(params(), idempotency_key: "second-key", executor_id: "second", ticket: "777")
    second = capture_io(fn -> assert 0 == ExecutorRequest.request(other, decision_store: store) end) |> Jason.decode!()
    refute first["decision_id"] == second["decision_id"]
    assert second["status"] == "accepted"
    assert {:ok, decision} = DecisionStore.get(second["decision_id"], store)
    assert %{executor_id: "second", ticket: "777"} = decision.requester
  end

  test "answering one Executor request does not dismiss an independent matching request", %{store: store} do
    opts = Keyword.put(params(), :blocking, false)
    first = capture_io(fn -> assert 0 == ExecutorRequest.request(opts, decision_store: store) end) |> Jason.decode!()
    second = capture_io(fn -> assert 0 == ExecutorRequest.request(Keyword.put(opts, :idempotency_key, "second"), decision_store: store) end) |> Jason.decode!()

    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(first["decision_id"], %{expected_version: 1, option_id: "ship", idempotency_key: "answer-first"}, [actor: %{kind: :operator, id: "human"}], store)

    assert {:ok, remaining} = DecisionStore.get(second["decision_id"], store)
    assert remaining.decision_status == :open
    assert remaining.answer == nil
  end

  test "a separate request does not retire an expired Executor Command", %{store: store} do
    first = capture_io(fn -> assert 0 == ExecutorRequest.request(params(), decision_store: store) end) |> Jason.decode!()
    assert {:ok, %{status: :accepted}} = DecisionStore.expire(first["decision_id"], "expired", [], store)
    second = capture_io(fn -> assert 0 == ExecutorRequest.request(Keyword.put(params(), :idempotency_key, "replacement"), decision_store: store) end) |> Jason.decode!()
    refute second["decision_id"] == first["decision_id"]
    assert {:ok, original} = DecisionStore.get(first["decision_id"], store)
    assert original.decision_status == :expired
  end

  test "retrying an expired Executor key remains an idempotent duplicate", %{store: store} do
    first = capture_io(fn -> assert 0 == ExecutorRequest.request(params(), decision_store: store) end) |> Jason.decode!()
    assert {:ok, %{status: :accepted}} = DecisionStore.expire(first["decision_id"], "expired", [], store)

    for _retry <- 1..2 do
      result = capture_io(fn -> assert 0 == ExecutorRequest.request(params(), decision_store: store) end) |> Jason.decode!()
      assert result["decision_id"] == first["decision_id"]
      assert result["version"] == 1
      assert result["status"] == "duplicate"
    end
  end

  test "invalid UTF-8 context is refused without crashing the store", %{store: store} do
    opts = Keyword.put(params(), :long_context_markdown, <<255>>)
    assert capture_io(:stderr, fn -> assert 64 == ExecutorRequest.request(opts, decision_store: store) end) =~ "valid UTF-8"
    assert Process.alive?(store)
  end

  test "public entry point delegates through guarded CLI protocol" do
    output = capture_io(fn -> assert :ok = Aiur.AgentControlCLI.command_request(question: "Ship?", options: ["invalid"]) end)
    assert output =~ "--option expects id=label"
    assert output =~ "__AIUR_CONTROL_EXIT__:64"
  end

  test "generated key is printed and can be reused", %{store: store} do
    opts = Keyword.drop(params(), [:idempotency_key, :json])
    output = capture_io(fn -> assert 0 == ExecutorRequest.request(opts, decision_store: store) end)
    assert [_, key] = Regex.run(~r/Idempotency key: (exec-[\w-]+)/, output)
    assert output =~ "Created Command dec_"
    assert output =~ "(needs you)"
    assert output =~ "aiur commands dec_"
    retry = capture_io(fn -> assert 0 == ExecutorRequest.request(Keyword.put(opts, :idempotency_key, key), decision_store: store) end)
    assert retry =~ "Existing Command"
  end

  test "invalid option and dangling recommendation are rejected", %{store: store} do
    for {opts, message} <- [{Keyword.put(params(), :options, ["invalid"]), "id=label"}, {Keyword.put(params(), :recommend, "missing"), "supplied option"}] do
      assert capture_io(:stderr, fn -> assert 64 == ExecutorRequest.request(opts, decision_store: store) end) =~ message
    end
  end

  test "control RPC allowlist accepts creation as a write and refuses request attribution injection" do
    expression = ~s|Aiur.AgentControlCLI.command_request(question: "Ship?", options: ["yes=Ship", "no=Wait"], urgency: "normal", json: true)|
    assert {:ok, %{scope: :write, function: :command_request}} = Aiur.ControlCall.parse(expression)
    assert {:error, :scope_exceeds_max} = Aiur.ControlCall.parse(expression, max_scope: :read)
    assert {:error, :option_not_allowed} = Aiur.ControlCall.parse(~s|Aiur.AgentControlCLI.command_request(question: "Ship?", authority: :supervisor_allowed)|)
  end

  # Future regression guard: this worker validation already exists on main.
  test "worker human-required requests still require authority basis" do
    assert {:error, {:decision_invalid, {:authority, :human_required_basis_required}}} =
             DecisionValidation.normalize(%{question: "Ship?", blocking: true, authority: :human_required}, ticket: %{identifier: "6410"})
  end

  test "Executor suggested responses are checked" do
    assert {:warn, :too_few_options} = RequestContent.suggested_response_check(%{options: []}, :executor_cli)
  end
end
