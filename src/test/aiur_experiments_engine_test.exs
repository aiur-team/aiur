defmodule AiurExperimentsEngineTest do
  use ExUnit.Case, async: true
  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  defp run_engine(args, input \\ "") do
    System.cmd("bash", ["-c", "printf '%s' \"$EXPERIMENT_INPUT\" | (source \"$AIUR_ENGINE\"; run_control_rpc() { echo \"RPC:$1\"; }; aiur_engine_main \"$@\")", "experiments-test" | args],
      env: [{"AIUR_ENGINE", @engine}, {"EXPERIMENT_INPUT", input}, {"AIUR_RELEASE_NODE", "experiments-test@127.0.0.1"}],
      stderr_to_stdout: true
    )
  end

  test "dispatches experiments and transports stdin and hostile text without interpolation" do
    assert {"RPC:Aiur.AgentControlCLI.experiments([verb: :list, argv: []])\n", 0} = run_engine(["experiments", "list"])
    # "})
    payload = ~s({"title":"\"; System.halt(99)
    {output, 0} = run_engine(["experiments", "create", "--from", "-"], payload)
    encoded = Base.encode64("--spec-json=" <> payload)
    assert output == "RPC:Aiur.AgentControlCLI.experiments([verb: :create, argv: [ Base.decode64!(\"#{encoded}\")]])\n"
    refute output =~ payload
    title = ~s|$(touch unwanted)"; System.halt(99)|
    {output, 0} = run_engine(["experiments", "create", "--title", title, "--line", "manual:smoke", "--metric", "delivery/start:decrease"])
    assert output =~ Base.encode64(title)
    refute output =~ title
  end

  test "metrics and events JSON dispatch reach the control RPC" do
    {output, 0} = run_engine(["experiments", "metrics", "--json"])
    assert output =~ "verb: :metrics"
    assert output =~ Base.encode64("--json")
    {output, 0} = run_engine(["experiments", "events", "delivery-change", "--json", "--refresh"])

    assert output ==
             "RPC:Aiur.AgentControlCLI.experiments([verb: :events, argv: [ Base.decode64!(\"#{Base.encode64("delivery-change")}\"), Base.decode64!(\"#{Base.encode64("--json")}\"), Base.decode64!(\"#{Base.encode64("--refresh")}\")]])\n"
  end

  test "freeze transports the window, revision reason and JSON option through RPC" do
    args = ["baseline", "--window", "before", "--reason", ~s|$(touch unwanted); "reason"|, "--json"]
    {output, 0} = run_engine(["experiments", "freeze" | args])
    assert output =~ "verb: :freeze"
    for arg <- args, do: assert(output =~ Base.encode64(arg))
    refute output =~ "$(touch unwanted)"
  end

  test "rejects absent verbs and a line lacking its reference before invoking RPC" do
    assert {output, 64} = run_engine(["experiments"])
    assert output =~ "expects list, show, events, metrics, create or freeze"
    assert {output, 64} = run_engine(["experiments", "create", "--line", "release"])
    assert output =~ "requires type:ref"
    refute output =~ "RPC:"
  end

  test "dev shim recognizes experiments as a control command without a rebuild" do
    shim = File.read!(Path.expand("../../scripts/aiurdev", __DIR__))

    for {function, code} <- [{"targets_release_deliberately", 1}, {"pure_control_command", 0}] do
      [definition] = Regex.run(~r/^#{function}\(\) \{.*?^\}/ms, shim)
      assert {"", ^code} = System.cmd("bash", ["-c", definition <> "\n#{function} experiments"])
    end
  end
end
