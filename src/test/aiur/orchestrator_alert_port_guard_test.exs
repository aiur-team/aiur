defmodule Aiur.OrchestratorAlertPortGuardTest do
  use ExUnit.Case, async: true

  # Regression guard: orchestrator code reaches alerts only through Aiur.Signal.
  # The tree-wide form (only signal.ex calls Alerts.emit_*) lands with C5-T04/T05.
  test "orchestrator code does not call Aiur.Alerts directly" do
    lib = Path.expand("../../lib/aiur", __DIR__)

    violations =
      [Path.join(lib, "orchestrator.ex") | Path.wildcard(Path.join(lib, "orchestrator/**/*.ex"))]
      |> Enum.filter(&(File.read!(&1) =~ ~r/\bAlerts\.emit_/))
      |> Enum.map(&Path.relative_to(&1, lib))

    assert violations == [], "route alerts through Aiur.Signal:\n" <> Enum.join(violations, "\n")
  end
end
