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

  test "passes --after blockers to the request RPC and the allowlist accepts them" do
    for flag <- ["--after '5,#6'", "--after='5,#6'"] do
      {out, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_command request 'Which build?' #{flag}|, [])
      assert out =~ ~s|after: Base.decode64!("#{Base.encode64("5,#6")}")|
    end

    assert {:ok, %{function: :command_request}} = Aiur.ControlCall.parse(~s|Aiur.AgentControlCLI.command_request(question: "Q?", after: "5,6")|)
  end

  test "command cancel sends one pending ID and refuses anything else before RPC" do
    {out, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_command cancel pend_1a2b3c4d|, [])
    assert out =~ ~s|RPC:Aiur.AgentControlCLI.command_cancel([pending_id: "pend_1a2b3c4d"])|
    assert {:ok, %{function: :command_cancel}} = Aiur.ControlCall.parse(~s|Aiur.AgentControlCLI.command_cancel([pending_id: "pend_1a2b3c4d"])|)

    for args <- ["cancel", "cancel dec_123", "cancel 'pend_1a2b3c4d\"]); x(['", "cancel pend_1a2b3c4d extra"] do
      {out, 64} = run_sourced_engine("run_control_rpc() { echo RPC_CALLED; }\ncmd_command #{args}", [])
      assert out =~ "expects one pending ID"
      refute out =~ "RPC_CALLED"
    end
  end

  @tag :tmp_dir
  test "passes repeatable media and resolves a relative file on the caller's machine", %{tmp_dir: dir} do
    script = ~s|run_control_rpc() { echo "RPC:$1"; }\ncd "$MEDIA_DIR" && cmd_command request 'Ship?' --media 'shot.png,alt=A, b' --media=https://github.com/a.gif|
    {out, 0} = run_sourced_engine(script, [{"MEDIA_DIR", dir}])
    assert out =~ ~s|media: [Base.decode64!("#{Base.encode64(Path.join(dir, "shot.png") <> ",alt=A, b")}"), Base.decode64!("#{Base.encode64("https://github.com/a.gif")}")]|
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
    for args <- ["request", "request 'Ship?' --option", "request 'Ship?' --urgency tomorrow", "request 'Ship?' --context-file '#{dir}/missing'"] do
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

  test "relayed command answer passes an explicit idempotency key safely" do
    script = ~S|run_control_rpc() { echo "RPC:$1"; }
cmd_command dec_0123456789abcdef --option yes --relayed --quote 'Operator chose yes' --idempotency-key retry-1|

    {out, 0} = run_sourced_engine(script, [{"AIUR_AGENT_WORKSPACE", nil}])

    assert out =~ "Aiur.AgentControlCLI.operator_relay_answer(["
    assert out =~ ~s|idempotency_key: Base.decode64!("#{Base.encode64("retry-1")}")|
    assert out =~ "caller_cwd: Base.decode64!("
  end

  test "idempotency key is accepted only for relayed answers" do
    {out, 64} =
      run_sourced_engine(
        ~S|run_control_rpc() { echo RPC_CALLED; }
cmd_command dec_0123456789abcdef --option yes --idempotency-key retry-1|,
        []
      )

    assert out =~ "requires --relayed"
    refute out =~ "RPC_CALLED"
  end
end
