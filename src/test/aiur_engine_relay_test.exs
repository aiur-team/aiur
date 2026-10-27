defmodule AiurEngineRelayTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.EngineCase

  test "operator-relay-answer safely encodes quote, relayer and concurrency fields" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_operator_relay_answer 'decision:42' --expected-version 3 --option keep --quote 'keep them' --relayed-by attended-executor --idempotency-key 'relay:42:v3'|,
        []
      )

    assert out =~ "RPC:Aiur.AgentControlCLI.operator_relay_answer(["
    assert out =~ ~s|quote: Base.decode64!("a2VlcCB0aGVt")|
    assert out =~ ~s|relayed_by: Base.decode64!("YXR0ZW5kZWQtZXhlY3V0b3I=")|
    assert out =~ "expected_version: 3"
    assert out =~ ~s|option_id: Base.decode64!("a2VlcA==")|
    assert out =~ ~s|idempotency_key: Base.decode64!("cmVsYXk6NDI6djM=")|
  end

  test "operator-relay-answer refuses missing relay evidence and ambiguous answers" do
    for {argv, message} <- [
          {"decision:42 --expected-version 1 --option keep --relayed-by exec --idempotency-key key", "--quote is required"},
          {"decision:42 --expected-version 1 --option keep --quote yes --idempotency-key key", "--relayed-by must not be empty"},
          {"decision:42 --expected-version 1 --option keep --custom-response yes --quote yes --relayed-by exec --idempotency-key key", "exactly one of --option or --custom-response"}
        ] do
      {out, 64} = run_sourced_engine("run_control_rpc() { echo RPC_CALLED; }\ncmd_operator_relay_answer #{argv}", [])
      assert out =~ message
      refute out =~ "RPC_CALLED"
    end
  end

  test "operator-relay-answer dispatches through the live control path" do
    rel = fake_release()
    env = [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}]

    {relay, _code} =
      run_engine_real(
        ["operator-relay-answer", "decision:42", "--expected-version", "3", "--option", "keep", "--quote", "keep them", "--relayed-by", "attended-executor", "--idempotency-key", "relay:42:v3"],
        env
      )

    assert relay =~ "Aiur.AgentControlCLI.operator_relay_answer(["
    assert relay =~ "quote: Base.decode64!"
  end
end
