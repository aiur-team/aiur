defmodule Aiur.AgentControlCLIDelegationTest do
  use ExUnit.Case, async: true

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
end
