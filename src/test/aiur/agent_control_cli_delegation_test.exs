defmodule Aiur.AgentControlCLIDelegationTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.TodoCLI

  @libexec Path.expand("../../../packaging/npm/aiur-cli/libexec", __DIR__)

  test "every launcher-called AgentControlCLI function is exported" do
    exported = Aiur.AgentControlCLI.__info__(:functions) |> Keyword.keys() |> MapSet.new()

    # The engine is split into sourced modules, so scan every launcher shell file.
    scripts = Path.wildcard(Path.join(@libexec, "**/*.sh"))
    assert scripts != []

    called =
      ~r/Aiur\.AgentControlCLI\.([a-z_]+[?!]?)\(/
      |> Regex.scan(Enum.map_join(scripts, "\n", &File.read!/1), capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert "executor_wait" in called
    assert Enum.reject(called, &MapSet.member?(exported, String.to_atom(&1))) == []
  end

  test "executor verbs keep their zero-arg and options arities after the move" do
    Code.ensure_loaded!(Aiur.AgentControlCLI)

    for {name, arities} <- [
          executor_wait: [0, 1],
          executor_roster: [0, 1],
          executor_claim: [0, 1],
          executor_release: [0, 1],
          executor_listen: [0, 1],
          executor_revoke: [1, 2],
          executor_fast_forward: [1, 2]
        ],
        arity <- arities do
      assert function_exported?(Aiur.AgentControlCLI, name, arity), "#{name}/#{arity}"
    end
  end

  # Future regression guard: the launcher retains both default-message arities.
  test "control verbs retain all launcher arities after extraction" do
    exported = MapSet.new(Aiur.AgentControlCLI.__info__(:functions))

    for {name, arity} <- [pause: 1, resume: 1, reset_budget: 1, pause_global: 0, resume_global: 0, set_max_agents: 1, message: 2, message: 3] do
      assert MapSet.member?(exported, {name, arity}), "missing #{name}/#{arity}"
    end
  end

  test "todo delegates both arities to the orchestration component" do
    source = File.read!(Path.expand("../../lib/aiur/agent_control_cli.ex", __DIR__))
    assert source =~ "defdelegate todo(issue_ids, opts"
    assert source =~ "to: Aiur.Orchestrator.TodoCLI"
    assert {:todo, 1} in TodoCLI.__info__(:functions)
    assert {:todo, 2} in TodoCLI.__info__(:functions)
    refute source =~ "defp queue_todo_issue("
  end

  # Future regression guard: build-queue behavior remains in its existing module.
  test "queue forwards to BuildQueueCLI without owning build-queue behavior" do
    source = File.read!(Path.expand("../../lib/aiur/agent_control_cli.ex", __DIR__))
    assert source =~ "defdelegate queue(opts"
    assert source =~ "to: Aiur.ControlCLI.EntryPoints"
    glue = File.read!(Path.expand("../../lib/aiur/control_cli/entry_points.ex", __DIR__))
    queue = glue |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "  def queue("))
    assert [line] = queue
    assert line =~ "Aiur.BuildQueueCLI.run()"
    assert {:run, 1} in Aiur.BuildQueueCLI.__info__(:functions)
    refute source =~ "BuildQueue."
  end
end
