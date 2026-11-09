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
        {"queue show --queue --json", ~S|cmd_queue show --queue wave --json|},
        {"queue add ids/--queue/--after/--start-on", ~S|cmd_queue add 12 13 --queue wave --after 5 --start-on pr_merged|},
        {"queue add --at --rank", ~S|cmd_queue add 12 --queue wave --at 2 --rank 3|},
        {"queue add --build-order", ~S|cmd_queue add --build-order 2573|},
        {"queue add --feature", ~S|cmd_queue add --feature my-feat|},
        {"queue add --epic", ~S|cmd_queue add --epic infra|},
        {"queue set", ~S|cmd_queue set wave --start-on default|},
        {"queue remove", ~S|cmd_queue remove 12|},
        {"queue reorder --to", ~S|cmd_queue reorder 12 --to 1|},
        {"queue hold", ~S|cmd_queue hold --queue wave|},
        {"queue release", ~S|cmd_queue release --queue wave|},
        {"queue recover --force", ~S|cmd_queue recover --force|},
        {"queue clear --remove-markers --yes", ~S|cmd_queue clear --remove-markers --yes|},
        {"units all options", ~S|cmd_units --scope unfinished --condition queued,alert --format records --json|},
        {"build-orders", ~S|cmd_build_orders 1363 --json|},
        {"analytics all flags", ~S|cmd_analytics --range full --since 2026-08-09T10:00:00Z --until 2026-08-09T11:00:00Z --build-order 1595 --json|},
        {"lane confirm --lane --as --json", ~S|cmd_lane confirm 12 --lane infra --as kevin --json|},
        {"lane confirm --epic", ~S|cmd_lane confirm 12 --epic infra|},
        {"lane set --as --source", ~S|cmd_lane set infra 12 13 --as kevin|},
        {"lane clear", ~S|cmd_lane clear 12 --as kevin|},
        {"lane show --unconfirmed --json", ~S|cmd_lane show 12 --unconfirmed --json|},
        {"lane list --json", ~S|cmd_lane list --json|},
        {"epic show --json", ~S|cmd_epic show big --json|},
        {"epic list --json", ~S|cmd_epic list --json|},
        {"epic create --label --icon --hue --root --as --json", ~S|cmd_epic create bugs --label Bugs --icon bug-ant --hue 200 --root 12 --as kevin --json|},
        {"epic edit --label --hue", ~S|cmd_epic edit bugs --label Renamed --hue 359|},
        {"epic add", ~S|cmd_epic add combat-epic combat khala-srv --json|},
        {"epic remove", ~S|cmd_epic remove combat-epic combat|},
        {"feature show --unconfirmed", ~S|cmd_feature show my-feat --unconfirmed --json|},
        {"feature add --lane --move --source", ~S|cmd_feature add s 1 --lane phase-1 --move --source backfill-agent --json|},
        {"feature create --label --hue --lane --lane-icon --in", ~S|cmd_feature create s --label Name --hue 000 --lane a=First --lane b=Second --lane-icon a=bug-ant --in infra|},
        {"feature edit --end --add-lane --label", ~S|cmd_feature edit s --end now --add-lane a=New  --label Renamed|},
        {"feature remove", ~S|cmd_feature remove s 1|},
        {"feature also --remove", ~S|cmd_feature also s 1 --remove|},
        {"feature baseline --replace", ~S|cmd_feature baseline s --replace|},
        {"feature confirm", ~S|cmd_feature confirm s 1|},
        {"set KEY VALUE", ~S|cmd_set agent.max_concurrent_agents 3|},
        {"set --unset", ~S|cmd_set --unset agent.max_concurrent_agents|}
      ] do
    test "#{name} in a git checkout carries the cwd hint and parses locally", %{dir: dir} do
      out = sh(dir, unquote(command))
      hint = ~s|project_hint: Base.decode64!("#{Base.encode64("o/hinted")}")|
      assert Regex.match?(~r/#{Regex.escape(hint)}\]?\)$/, out)
      assert {:ok, _call} = Aiur.ControlCall.parse(out, remote: false)

      # Minus the hint, the inner call is exactly what a checkout with no repo sends.
      {bare, 0} = System.cmd("bash", ["-c", ~S|source "$1"; run_control_rpc() { printf '%s' "$1"; }; | <> unquote(command), "t", @engine], cd: "/", env: @env)
      # caller_cwd is the checkout path by design; everything else must match.
      cwd = fn path -> Base.encode64(path) end
      inner = out |> String.replace(", " <> hint, "") |> String.replace(hint, "") |> String.replace(cwd.(dir), cwd.("/"))
      assert inner == bare
    end
  end

  test "only commands that join project keywords wrap; config explain and set max-agents do not", %{dir: dir} do
    flag = ~S|; printf ' wrap=%s' "${AIUR_PROJECT_WRAP:-none}"|

    assert sh(dir, "cmd_queue show" <> flag) =~ " wrap=1"
    assert sh(dir, "cmd_config explain agent.priority --json" <> flag) =~ " wrap=none"
    assert sh(dir, "cmd_set max-agents 3" <> flag) =~ " wrap=none"
  end
end
