defmodule Aiur.AgentControlCLIDelegationTest do
  use ExUnit.Case, async: true

  @engine Path.expand("../../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  test "every launcher-called AgentControlCLI function is exported" do
    exported = Aiur.AgentControlCLI.__info__(:functions) |> Keyword.keys() |> MapSet.new()

    called =
      ~r/Aiur\.AgentControlCLI\.([a-z_]+[?!]?)\(/
      |> Regex.scan(File.read!(@engine), capture: :all_but_first)
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
