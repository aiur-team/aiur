defmodule AiurEngineProjectHintTest do
  # Runs the launcher inside a real git checkout with a GitHub origin: every project-scoped command then
  # carries the cwd `project_hint:` and is wrapped for ControlCall (AIUR_PROJECT_WRAP).
  use ExUnit.Case, async: false

  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)
  @env [{"AIUR_AGENT_WORKSPACE", ""}, {"AIUR_PROJECT_ROOT", ""}, {"AIUR_REPO_ROOT", ""}]

  setup do
    # parse/2 resolves option atoms with to_existing_atom; load the module that defines project_hint.
    Code.ensure_loaded!(Aiur.ControlCall.Project)
    # Outside any */aiur-workspaces/* path so the queue write guard does not fire.
    dir = Path.join("/dev/shm", "aiur-hint-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", dir])
    {_, 0} = System.cmd("git", ["-C", dir, "remote", "add", "origin", "https://github.com/o/hinted.git"])
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp sh(dir, command) do
    script = ~S|source "$1"; shift; run_control_rpc() { printf '%s' "$1"; }; | <> command
    {out, 0} = System.cmd("bash", ["-c", script, "t", @engine], cd: dir, env: @env)
    out
  end

  for {name, command} <- [
        {"queue show", ~S|cmd_queue show|},
        {"queue clear", ~S|cmd_queue clear --remove-markers --yes|},
        {"queue add start_on", ~S|cmd_queue add 12 --start-on pr_merged|},
        {"units condition", ~S|cmd_units --condition queued,alert --json|},
        {"build-orders", ~S|cmd_build_orders 1363 --json|}
      ] do
    test "#{name} in a git checkout carries the cwd hint and parses locally", %{dir: dir} do
      out = sh(dir, unquote(command))
      assert String.ends_with?(out, ~s|project_hint: Base.decode64!("#{Base.encode64("o/hinted")}")])|)
      assert {:ok, _call} = Aiur.ControlCall.parse(out, remote: false)
    end
  end

  test "only commands that join project keywords wrap; config explain and set max-agents do not", %{dir: dir} do
    flag = ~S|; printf ' wrap=%s' "${AIUR_PROJECT_WRAP:-none}"|

    assert sh(dir, "cmd_queue show" <> flag) =~ " wrap=1"
    assert sh(dir, "cmd_config explain agent.priority --json" <> flag) =~ " wrap=none"
    assert sh(dir, "cmd_set max-agents 3" <> flag) =~ " wrap=none"
  end
end
