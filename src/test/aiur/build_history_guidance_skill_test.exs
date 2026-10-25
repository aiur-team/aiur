defmodule Aiur.BuildHistoryGuidanceSkillTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.EngineCase
  alias Aiur.AgentTools.Dispatch
  alias Aiur.BuildOrder.Estimates
  @root Path.expand("../../..", __DIR__)
  @filing ~w(aiur-agent/conventions.md aiur-run/SKILL.md aiur-run/references/executor.md aiur-meta/SKILL.md aiur-build/SKILL.md aiur-build/references/planning-contract.md)
  @full ~w(aiur-agent/conventions.md aiur-run/references/executor.md)
  @planning ~w(aiur-build/SKILL.md aiur-run/SKILL.md)
  @fill %{"<epic>" => "infra", "<ids…>" => "101 102", "<id>" => "101", "<slug>" => "docs-site", "<hours>" => "7", "<cause>" => "needs review", "<old>" => "2", "<new>" => "7", "<why>" => "review done"}

  test "every filing doc states the home-page epic rule" do
    for path <- @filing, do: assert(blocks(path, "home-page epic") != "", "#{path} no longer states the home-page epic rule")
    assert blocks("aiur-run/references/executor.md", "home-page epic") =~ "--move"
    assert blocks("aiur-build/SKILL.md", "home-page epic") =~ "feature"
  end

  test "every documented build-history command is accepted by the real engine checks" do
    text = Enum.map_join(@filing, &blocks(&1, "home-page epic")) <> Enum.map_join(@planning, &blocks(&1, "estimate override"))
    commands = for [_, command] <- Regex.scan(~r/`(aiur (?:epic|feature|ticket estimate) [^`]+)`/, text), do: command
    for family <- ~w(epic feature ticket), do: assert(Enum.any?(commands, &String.starts_with?(&1, "aiur #{family} ")), "no command found for #{family}")

    for command <- commands do
      filled = Enum.reduce(@fill, command, fn {key, value}, acc -> String.replace(acc, key, value) end)
      refute filled =~ ~r/<[^>]+>/, "unknown placeholder: #{command}"
      assert {output, 0} = parser(filled), command
      assert output =~ "RPC:Aiur.AgentControlCLI.", command
    end

    for invalid <- ["aiur epic set infra", "aiur epic set infra 101 --source agent:101", "aiur ticket estimate 101 7", "aiur epic nonexistent"] do
      assert {output, 64} = parser(invalid)
      refute output =~ "RPC:"
    end
  end

  test "no epic block teaches an epic label" do
    for path <- @full do
      text = blocks(path, "home-page epic")
      assert text =~ ~r/Never[^.]*`epic:<name>`[^.]*parks[^.]*`epic`/s
      assert Regex.scan(~r/`(epic[^`]*)`/, text) |> Enum.map(&List.last/1) |> Enum.uniq() |> Enum.sort() == ["epic", "epic:<name>"]
    end
  end

  test "the epic rule leaves an unknown category unset" do
    for path <- @full, phrase <- ["Unsorted", "set none", "list of valid keys", "type label matches", "else Unsorted"], do: assert(blocks(path, "home-page epic") =~ phrase)
  end

  test "Executor entry skills link to the full category rule concisely" do
    for {path, link} <- [{"aiur-run/SKILL.md", "references/executor.md"}, {"aiur-meta/SKILL.md", "../aiur-run/references/executor.md"}] do
      text = blocks(path, "home-page epic")
      assert String.length(text) <= 500
      assert text =~ link
      assert text =~ "aiur epic set"
      assert text =~ "aiur feature add"
    end
  end

  test "the issue-worker rule uses real tools and never blocks filing" do
    text = blocks("aiur-agent/conventions.md", "home-page epic")
    assert text =~ "never block filing"
    assert text =~ "workpad"
    refute text =~ "aiur epic set"
    refute text =~ "--source"
    specs = Map.new(Dispatch.tool_specs(), &{&1["name"], &1})
    examples = Regex.scan(~r/`(aiur_\w+) (\{[^`]+\})`/, text)
    assert length(examples) == 2

    for [_, tool, json] <- examples do
      assert spec = specs[tool]
      args = Jason.decode!(json)
      properties = spec["inputSchema"]["properties"]
      assert Enum.all?(Map.keys(args), &Map.has_key?(properties, &1))
      assert Enum.all?(spec["inputSchema"]["required"] || [], &Map.has_key?(args, &1))
      if Map.has_key?(args, "op"), do: assert(args["op"] in properties["op"]["enum"])
    end
  end

  test "estimate overrides need a strong reason and are not resizing" do
    hours = Enum.map_join(1..5, ", ", &Estimates.default_hours/1)

    for path <- @planning do
      text = blocks(path, "estimate override")
      for phrase <- [hours, "strong", "fix the complexity label or split", "one line", "500", "--reason", "--clear"], do: assert(text =~ phrase)
    end
  end

  test "skills.md points at the commands once" do
    text = File.read!(Path.join(@root, "website/docs-app/skills.md"))
    for name <- ["aiur_set_epic", "aiur epic set", "aiur ticket estimate"], do: assert(length(String.split(text, name)) == 2)
    [worker_notes, _executor_notes] = String.split(text, "## Executor skills", parts: 2)
    assert worker_notes =~ "For a home-page epic"
  end

  defp blocks(path, marker) do
    Path.join([@root, ".claude/skills", path]) |> File.read!() |> String.split(~r/\n\s*\n/) |> Enum.filter(&String.contains?(&1, marker)) |> Enum.join("\n\n")
  end

  defp parser(command) do
    script = ~S|run_control_rpc() { echo "RPC:$1"; }; | <> String.replace_prefix(command, "aiur ", "cmd_")
    run_sourced_engine(script, [{"USER", "guidance-test"}])
  end
end
