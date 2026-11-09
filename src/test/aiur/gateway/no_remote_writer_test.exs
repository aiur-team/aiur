defmodule Aiur.Gateway.NoRemoteWriterTest do
  use ExUnit.Case, async: true

  alias Aiur.ControlCall.Allowlist

  # Local-only writers. Anything else that calls Registry.write/2 must be added here deliberately.
  # The enrol controller is not a control call: it adds one read-only entry, and only for a caller holding a live invite secret.
  @local_writers ~w(lib/aiur/gateway/cli.ex lib/aiur/gateway/grant_confirmation.ex lib/aiur/gateway/registry.ex lib/aiur_web/controllers/gateway_enroll_controller.ex)

  # A source scan, not a call graph: it sees every direct reference to the writer, which is what an allowlist
  # entry would have to make. (An xref walk of the whole app was too slow to run in the suite.)
  test "only the local CLI and the human confirmation call Registry.write/2" do
    callers =
      for file <- Path.wildcard(Path.expand("../../../lib/**/*.ex", __DIR__)),
          File.read!(file) =~ ~r/Registry\.write\(|Registry\.write\/2/,
          do: Path.relative_to(file, Path.expand("../../..", __DIR__))

    assert Enum.sort(callers) -- @local_writers == []
    assert "lib/aiur/gateway/cli.ex" in callers, "the scan must see the CLI, or it constrains nothing"
  end

  test "no allowlist entry points at a module that calls the writer" do
    writers = Enum.map(@local_writers, &(&1 |> Path.basename(".ex") |> Macro.camelize()))
    modules = for {{segments, _function, _arity}, _} <- Allowlist.entries(), do: segments |> List.last() |> Atom.to_string()

    assert Enum.filter(modules, &(&1 in writers)) == []
    refute Enum.any?(Allowlist.entries(), fn {{segments, _, _}, _} -> segments == [:Aiur, :Gateway, :Cli] end)
  end
end
