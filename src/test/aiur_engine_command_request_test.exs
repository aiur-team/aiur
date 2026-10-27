defmodule AiurEngineCommandRequestTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.EngineCase

  test "dispatches request and safely encodes every supplied string" do
    script =
      ~S|run_control_rpc() { echo "RPC:$1"; }
cmd_command request 'Ship $(echo unsafe)?' --option no=Wait --option 'yes=Ship=now' --recommend yes --ticket 6410 --short-summary 'Beta release' --executor-id exec --idempotency-key retry --urgency high --blocking --json|

    {out, 0} = run_sourced_engine(script, [])
    assert out =~ "RPC:Aiur.AgentControlCLI.command_request(["

    for {key, value} <- [question: "Ship $(echo unsafe)?", recommend: "yes", ticket: "6410", short_summary: "Beta release", executor_id: "exec", idempotency_key: "retry", urgency: "high"] do
      assert out =~ ~s|#{key}: Base.decode64!("#{Base.encode64(value)}")|
    end

    assert out =~ ~s|options: [Base.decode64!("#{Base.encode64("no=Wait")}"), Base.decode64!("#{Base.encode64("yes=Ship=now")}")]|
    assert out =~ "blocking: true, json: true"
  end

  @tag :tmp_dir
  test "reads local context and rejects oversized files before RPC", %{tmp_dir: dir} do
    path = Path.join(dir, "context.md")
    File.write!(path, "More context\n")
    {out, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_command request 'Ship?' --context-file '#{path}'|, [])
    assert out =~ ~s|long_context_markdown: Base.decode64!("#{Base.encode64("More context")}")|
    File.write!(path, String.duplicate("x", 20_001))
    {out, 64} = run_sourced_engine(~s|run_control_rpc() { echo RPC_CALLED; }\ncmd_command request 'Ship?' --context-file '#{path}'|, [])
    assert out =~ "exceeds 20000 characters"
    refute out =~ "RPC_CALLED"
  end

  @tag :tmp_dir
  test "rejects unknown verbs, invalid flags and unreadable context", %{tmp_dir: dir} do
    for args <- ["unknown", "request", "request 'Ship?' --option", "request 'Ship?' --urgency tomorrow", "request 'Ship?' --context-file '#{dir}/missing'"] do
      {out, 64} = run_sourced_engine("run_control_rpc() { echo RPC_CALLED; }\ncmd_command #{args}", [])
      assert out =~ "aiur: command"
      refute out =~ "RPC_CALLED"
    end
  end

  test "live launcher dispatch reaches request RPC" do
    {out, _code} =
      run_engine_real(
        ["command", "request", "Ship?", "--option", "yes=Ship", "--option", "no=Wait"],
        [{"AIUR_RELEASE_DIR", fake_release()}, {"AIUR_BG_STATE_DIR", tmp_state()}]
      )

    assert out =~ "Aiur.AgentControlCLI.command_request(["
  end
end
