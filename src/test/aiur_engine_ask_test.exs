defmodule AiurEngineAskTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.EngineCase

  @tag :tmp_dir
  test "ask uses RPC, reads caller body files and preserves trailing newlines", %{tmp_dir: dir} do
    path = Path.join(dir, "body.md")
    File.write!(path, "Context\n\n")
    {out, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\nrun_ask ask 'Ship?' --body-file '#{path}'|, [{"AIUR_EXECUTOR_ID", "caller"}])
    assert out =~ "RPC:Aiur.AsksCLI.rpc("

    for value <- ["ask", "Ship?", "--body", "Context\n\n", "caller"] do
      assert out =~ Base.encode64(value)
    end
  end

  test "legacy list and done bypass RPC" do
    for args <- ["ask --done ask_old --note done", "ask --list --all", "ask --done=ask_old", "ask --note done --done ask_old", "ask --all --list"] do
      {out, 0} = run_sourced_engine(~s|run_asks() { echo "LOCAL:$*"; }\nrun_control_rpc() { exit 99; }\nrun_ask #{args}|, [])
      assert out =~ "LOCAL:"
    end
  end

  test "daemon down fails with an explicit Command diagnostic" do
    script = ~S|AIUR_CONTROL_COMMAND=ask
aiur_crash_marker_path() { echo /dev/null; }
print_not_running_message() { :; }
print_global_config_control_hint() { :; }
run_control_rpc() { print_control_down_message; return 1; }
run_ask ask 'Ship?'|
    {out, 1} = run_sourced_engine(script, [])
    assert out =~ "aiur ask now raises a Command and needs the running daemon"
  end

  test "launcher dispatches ask writes through RPC" do
    {out, _code} = run_engine_real(["ask", "Ship?"], [{"AIUR_RELEASE_DIR", fake_release()}, {"AIUR_BG_STATE_DIR", tmp_state()}])
    assert out =~ "Aiur.AsksCLI.rpc("
  end
end
