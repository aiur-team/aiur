defmodule AiurEngineCommandsTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "commands routes filters and encoded detail arguments through the control rpc" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_commands dec:42 --filter resolved --json --limit 10|,
        []
      )

    assert out =~ "RPC:Aiur.AgentControlCLI.commands([filter: :resolved, json: true, limit: 10, decision_id: Base.decode64!(\"ZGVjOjQy\")])"
  end

  test "units routes page-visible filters through the control rpc" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_units --scope unfinished --condition queued,alert --json|,
        []
      )

    assert out =~
             "RPC:Aiur.AgentControlCLI.units([scope: Base.decode64!(\"dW5maW5pc2hlZA==\"), conditions: [Base.decode64!(\"cXVldWVk\"), Base.decode64!(\"YWxlcnQ=\")], json: true])"
  end

  test "units forwards the human layout format" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_units --format records|,
        []
      )

    assert out =~
             "RPC:Aiur.AgentControlCLI.units([scope: Base.decode64!(\"bGl2ZQ==\"), format: Base.decode64!(\"cmVjb3Jkcw==\")])"

    {err, 64} = run_sourced_engine(~s|cmd_units --format|, [])
    assert err =~ "units --format requires a value"
  end

  test "bare units invocation routes an empty condition list" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_units|,
        []
      )

    assert out =~ "RPC:Aiur.AgentControlCLI.units([scope: Base.decode64!(\"bGl2ZQ==\")])"
  end

  test "commands reports missing option values as usage errors" do
    {out, 64} = run_sourced_engine(~s|cmd_commands --filter|, [])
    assert out =~ "commands --filter requires a value"
  end

  test "executor-answer safely routes one option answer through the control rpc" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_executor_answer 'decision:42' --expected-version 3 --option rebase --rationale 'Known stale branch' --idempotency-key 'exec:42:v3' --executor-id codex-executor|,
        []
      )

    assert out =~ "RPC:Aiur.AgentControlCLI.executor_answer(["
    assert out =~ "decision_id: Base.decode64!(\"ZGVjaXNpb246NDI=\")"
    assert out =~ "expected_version: 3"
    assert out =~ "option_id: Base.decode64!(\"cmViYXNl\")"
    assert out =~ "rationale: Base.decode64!(\"S25vd24gc3RhbGUgYnJhbmNo\")"
    assert out =~ "idempotency_key: Base.decode64!(\"ZXhlYzo0Mjp2Mw==\")"
    assert out =~ "executor_id: Base.decode64!(\"Y29kZXgtZXhlY3V0b3I=\")"
  end

  test "executor-answer --supersede asks the store to replace an undelivered answer" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_executor_answer 'decision:42' --expected-version 3 --custom-response 'New plan' --rationale 'Operator changed direction' --idempotency-key 'exec:42:s1' --supersede|,
        []
      )

    assert out =~ "RPC:Aiur.AgentControlCLI.executor_answer(["
    assert out =~ ", supersede: true])"

    {plain, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_executor_answer 'decision:42' --expected-version 3 --option yes --rationale why --idempotency-key key|,
        []
      )

    refute plain =~ "supersede"
  end

  test "executor mutations describe their attempted decision and version to the wrapper" do
    for {function, args} <- [
          {"cmd_executor_answer", "'decision:42' --expected-version 3 --option yes --rationale why --idempotency-key key"},
          {"cmd_executor_escalate", "'decision:42' --expected-version 3 --reason why"}
        ] do
      {out, 0} =
        run_sourced_engine(
          ~s|run_control_rpc() { echo "CONTEXT:$AIUR_CONTROL_ATTEMPT_CONTEXT"; }\n#{function} #{args}|,
          []
        )

      assert out =~ "CONTEXT:decision ID decision:42 with expected version 3"
    end
  end

  test "executor-answer requires one choice and all concurrency/audit fields" do
    for {argv, message} <- [
          {~s|'decision:42' --expected-version 3 --rationale why --idempotency-key key|, "exactly one of --option or --custom-response"},
          {~s|'decision:42' --expected-version 3 --option yes --custom-response yes --rationale why --idempotency-key key|, "exactly one of --option or --custom-response"},
          {~s|'decision:42' --option yes --rationale why --idempotency-key key|, "--expected-version expects a positive integer"},
          {~s|'decision:42' --expected-version 3 --option yes --idempotency-key key|, "--rationale is required"},
          {~s|'decision:42' --expected-version 3 --option yes --rationale why|, "--idempotency-key is required"}
        ] do
      {out, 64} = run_sourced_engine("cmd_executor_answer #{argv}", [])
      assert out =~ message
    end
  end

  test "executor-escalate safely routes one explicit operator alert" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_executor_escalate 'decision:42' --expected-version 3 --reason 'Irreversible scope change' --executor-id codex-executor|,
        []
      )

    assert out =~ "RPC:Aiur.AgentControlCLI.executor_escalate(["
    assert out =~ "decision_id: Base.decode64!(\"ZGVjaXNpb246NDI=\")"
    assert out =~ "expected_version: 3"
    assert out =~ "reason: Base.decode64!(\"SXJyZXZlcnNpYmxlIHNjb3BlIGNoYW5nZQ==\")"
    assert out =~ "executor_id: Base.decode64!(\"Y29kZXgtZXhlY3V0b3I=\")"
  end

  test "executor-escalate requires a decision, version, and reason" do
    for {argv, message} <- [
          {~s|--expected-version 3 --reason why|, "expects exactly one decision ID"},
          {~s|'decision:42' --reason why|, "--expected-version expects a positive integer"},
          {~s|'decision:42' --expected-version 3|, "--reason is required"}
        ] do
      {out, 64} = run_sourced_engine("cmd_executor_escalate #{argv}", [])
      assert out =~ message
    end
  end

  test "executor mutation commands dispatch through the live control path" do
    rel = fake_release()
    env = [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}]

    {answer, _code} =
      run_engine_real(
        [
          "executor-answer",
          "decision:42",
          "--expected-version",
          "3",
          "--custom-response",
          "Rebase it",
          "--rationale",
          "Known stale branch",
          "--idempotency-key",
          "exec:42:v3"
        ],
        env
      )

    {escalate, _code} =
      run_engine_real(
        ["executor-escalate", "decision:42", "--expected-version", "3", "--reason", "Irreversible"],
        env
      )

    assert answer =~ "Aiur.AgentControlCLI.executor_answer(["
    assert answer =~ "custom_response: Base.decode64!"
    assert escalate =~ "Aiur.AgentControlCLI.executor_escalate(["
  end

  test "build-orders routes its selector and JSON mode through the control rpc" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_build_orders 1363 --json|,
        []
      )

    assert out =~ "RPC:Aiur.AgentControlCLI.build_orders([json: true, root: Base.decode64!(\"MTM2Mw==\")])"
  end

  test "build-orders rejects multiple roots" do
    {out, 64} = run_sourced_engine(~s|cmd_build_orders 1363 1467|, [])
    assert out =~ "build-orders accepts at most one root"
  end

  test "analytics routes an explicit window through the control rpc" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_analytics --range full --since 2026-08-09T10:00:00Z --until 2026-08-09T11:00:00Z --build-order 1595 --json|,
        []
      )

    assert out =~ "RPC:Aiur.AgentControlCLI.analytics([range: :full, json: true"
    assert out =~ "since: Base.decode64!"
    assert out =~ "build_order: Base.decode64!"
  end

  test "github-cost routes the budget selection through the control rpc" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_github_cost --budget core --json|,
        []
      )

    assert out =~ ~s|RPC:Aiur.AgentControlCLI.github_cost([budget: "core", json: true])|
  end

  test "github-cost defaults to the GraphQL budget, which is the one that runs out" do
    {out, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_github_cost|, [])

    assert out =~ ~s|RPC:Aiur.AgentControlCLI.github_cost([budget: "graphql"])|
  end

  test "github-cost passes an output format through as an atom" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_github_cost --format records|,
        []
      )

    assert out =~ ~s|RPC:Aiur.AgentControlCLI.github_cost([budget: "graphql", format: :records])|
  end

  test "github-cost rejects malformed launcher arguments before an RPC" do
    for {argv, message} <- [
          {~s|--budget points|, "github-cost --budget accepts graphql, core or all"},
          {~s|--budget|, "github-cost --budget requires a value"},
          {~s|--format wide|, "github-cost --format accepts auto, table or records"},
          {~s|--format|, "github-cost --format requires a value"},
          {~s|--unknown|, "github-cost received an unknown option"},
          {~s|extra|, "github-cost does not accept positional arguments"}
        ] do
      {out, 64} = run_sourced_engine("cmd_github_cost #{argv}", [])
      assert out =~ message
    end
  end

  test "github-usage routes through the control rpc" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_github_usage --json|,
        []
      )

    assert out =~ ~s|RPC:Aiur.AgentControlCLI.github_usage([json: true])|
  end

  test "github-usage defaults to a plain per-actor report" do
    {out, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_github_usage|, [])

    assert out =~ ~s|RPC:Aiur.AgentControlCLI.github_usage([])|
  end

  test "github-usage rejects malformed launcher arguments before an RPC" do
    for {argv, message} <- [
          {~s|--unknown|, "github-usage received an unknown option"},
          {~s|extra|, "github-usage does not accept positional arguments"}
        ] do
      {out, 64} = run_sourced_engine("cmd_github_usage #{argv}", [])
      assert out =~ message
    end
  end

  test "analytics rejects malformed launcher arguments before an RPC" do
    for {argv, message} <- [
          {~s|--range week|, "analytics --range accepts run or full"},
          {~s|--build-order not-a-ticket|, "analytics --build-order expects a numeric ticket ID"},
          {~s|--build-order ''|, "analytics --build-order expects a numeric ticket ID"},
          {~s|--since|, "analytics --since requires a value"},
          {~s|--unknown|, "analytics received an unknown option"}
        ] do
      {out, 64} = run_sourced_engine("cmd_analytics #{argv}", [])
      assert out =~ message
    end
  end
end
