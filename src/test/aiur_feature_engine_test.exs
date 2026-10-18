defmodule Aiur.FeatureEngineTest do
  use ExUnit.Case, async: true

  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  defp shell(args, env \\ [], entry \\ "cmd_feature") do
    System.cmd(
      "bash",
      [
        "-c",
        ~S|source "$1"; shift; run_control_rpc() { printf '%s\n' "$1"; }; | <> entry <> ~S| "$@"|,
        "feature-test",
        @engine | args
      ],
      env: [{"USER", "tester"} | env],
      stderr_to_stdout: true
    )
  end

  defp opts(args) do
    {output, 0} = shell(args)
    expression = output |> String.trim() |> String.replace_prefix("Aiur.AgentControlCLI.feature(", "") |> String.trim_trailing(")")
    {opts, []} = Code.eval_string(expression)
    opts
  end

  test "feature add encodes slug and actor, strips hashes and collapses duplicates" do
    assert shell(["add", "khala-srv", "12", "#13", "12", "--json"]) ==
             {"Aiur.AgentControlCLI.feature([op: :add, slug: Base.decode64!(\"a2hhbGEtc3J2\"), ids: [12, 13], who: Base.decode64!(\"dGVzdGVy\"), json: true])\n", 0}

    assert opts(["add", "s", "1", "--epic", "phase-1", "--move", "--source", "backfill-agent"]) ==
             [op: :add, slug: "s", ids: [1], who: "tester", epic: "phase-1", move: true, source: "backfill-agent"]
  end

  test "create and edit preserve arbitrary text and repeated epics through RPC encoding" do
    text = ~S|quotes " and $(touch forbidden) `no`|

    assert opts(["create", "s", "--label", text, "--hue", "000", "--epic", "a=First", "--epic", "b=Second=part"]) ==
             [op: :create, slug: "s", who: "tester", label: text, hue: 0, epics: [%{key: "a", label: "First"}, %{key: "b", label: "Second=part"}]]

    assert opts(["edit", "s", "--end", "now", "--add-epic", "a=New", "--label", "Renamed"]) ==
             [op: :edit, slug: "s", who: "tester", end: "now", label: "Renamed", add_epics: [%{key: "a", label: "New"}]]
  end

  test "remove, also, baseline and show route their supported options" do
    assert opts(["remove", "s", "1"]) == [op: :remove, slug: "s", ids: [1], who: "tester"]
    assert opts(["also", "s", "1", "--remove"]) == [op: :also, slug: "s", ids: [1], who: "tester", remove: true]
    assert opts(["baseline", "s", "--replace"]) == [op: :baseline, slug: "s", who: "tester", replace: true]
    assert opts(["show"]) == [op: :show]
    assert opts(["show", "s", "--json"]) == [op: :show, slug: "s", json: true]
  end

  test "bad ids, hue, source and flags refuse the command before RPC" do
    for {args, message} <- [
          {["add", "s", "12a"], "ticket id"},
          {["add", "s", "0"], "ticket id"},
          {["add", "s", "2147483648"], "below 2147483648"},
          {["create", "s", "--label", "x", "--hue", "400"], "hue"},
          {["create", "s", "--label", "x", "--hue", "a"], "hue"},
          {["add", "s", "1", "--hue", "3"], "--hue"},
          {["add", "s", "1", "--source", "human"], "--source"},
          {["add", "s", "1", "--source", "agent:3"], "--source"},
          {["also", "s", "1", "--source", "backfill-agent"], "--source"},
          {["also", "s", "1", "--move"], "--move"},
          {["add", "s", "1", "--remove"], "--remove"},
          {["add", "s", "1", "--replace"], "--replace"},
          {["show", "s", "--as", "x"], "--as"},
          {["show", "s", "1"], "does not accept ticket ids"},
          {["edit", "s"], "at least one edit flag"},
          {["create", "s"], "--label"},
          {["create", "s", "--label", ""], "--label"},
          {["create", "s", "--label", "x", "--end", "now"], "--end"},
          {["edit", "s", "--add-epic", "missing-label="], "key=label"},
          {["remove", "s", "1", "--epic", "a"], "--epic"},
          {["create", "s", "--label", "x", "--epic", "missing"], "key=label"},
          {["add", "s"], "requires ticket ids"},
          {["add"], "requires a slug"},
          {["add", "s", "1", "--wat"], "unknown feature option"},
          {["confirm", "s"], "feature requires"},
          {["add", "s" | Enum.map(1..201, &to_string/1)], "at most 200"}
        ] do
      assert {output, 64} = shell(args), "expected usage error for #{inspect(args)}"
      assert output =~ message
      refute output =~ "Aiur.AgentControlCLI"
    end
  end

  test "unsafe or missing identity is refused and explicit identity restores writes" do
    for env <- [[{"USER", ""}], [{"USER", "a b"}]] do
      assert {output, 64} = shell(["add", "s", "1"], env)
      assert output =~ "valid --as or USER"
      refute output =~ "Aiur.AgentControlCLI"
    end

    assert {output, 64} = shell(["add", "s", "1", "--as", "a b"])
    assert output =~ "valid --as or USER"
    assert {output, 0} = shell(["add", "s", "1", "--as", "kevin"], [{"USER", ""}])
    assert output =~ ~S|who: Base.decode64!("a2V2aW4=")|
    assert shell(["show"], [{"USER", ""}]) == {"Aiur.AgentControlCLI.feature([op: :show])\n", 0}
  end

  test "shared entry point and usage expose all seven verbs" do
    assert shell(["feature", "show", "--json"], [], "aiur_engine_main") ==
             {"Aiur.AgentControlCLI.feature([op: :show, json: true])\n", 0}

    {help, 0} = shell([], [], "usage")
    for op <- ~w(create add remove also baseline edit show), do: assert(help =~ "aiur feature #{op}")
  end

  test "aiurdev feature controls the running daemon without deliberately rebuilding" do
    shim = Path.expand("../../scripts/aiurdev", __DIR__)
    source = File.read!(shim)

    for {function, code} <- [{"targets_release_deliberately", 1}, {"pure_control_command", 0}] do
      [definition] = Regex.run(~r/^#{function}\(\) \{.*?^\}/ms, source)

      assert {"", ^code} =
               System.cmd("bash", ["-c", definition <> "\n#{function} feature"], stderr_to_stdout: true)
    end
  end
end
