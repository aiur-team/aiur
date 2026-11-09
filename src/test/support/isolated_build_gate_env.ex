defmodule Aiur.TestSupport.IsolatedBuildGateEnv do
  @moduledoc false

  def prepare(root) do
    gate = Path.join(root, "build-gate")
    locks = gate <> ".locks"
    hook = Path.expand("../../priv/build_gate.bash", __DIR__)
    bin = Path.expand("../.aiur-runtime/build-bin", File.cwd!())

    for path <- [gate, locks], do: File.mkdir_p!(path)
    for slot <- 1..2, do: File.write!(Path.join(locks, "slot-#{slot}.lock"), "")
    File.write!(Path.join(locks, "phase-start.lock"), "")

    [
      {"BASH_ENV", hook},
      {"AIUR_BUILD_GATE_DIR", gate},
      {"AIUR_BUILD_GATE_LOCK_DIR", locks},
      {"AIUR_BUILD_GATE_SLOTS", "2"},
      {"AIUR_BUILD_GATE_BIN", bin},
      {"AIUR_BUILD_START_STAGGER_SECONDS", "0"},
      {"AIUR_BUILD_GATE_TIMEOUT_SECONDS", "30"},
      {"AIUR_BUILD_GATE_MAX_HOLD_SECONDS", "0"},
      {"AIUR_BUILD_GATE_RETAIN_SECONDS", "0"},
      {"AIUR_BUILD_GATE_LEASE_PATH", nil},
      {"AIUR_BUILD_GATE_LEASE_TOKEN", nil}
    ]
  end

  def isolated?(environment, root) do
    values = Map.new(environment)
    gate = Path.join(root, "build-gate")
    locks = gate <> ".locks"

    Map.fetch!(values, "AIUR_BUILD_GATE_DIR") == gate and
      Map.fetch!(values, "AIUR_BUILD_GATE_LOCK_DIR") == locks and
      Map.fetch!(values, "AIUR_BUILD_GATE_BIN") == Path.expand("../.aiur-runtime/build-bin", File.cwd!()) and
      Map.fetch!(values, "BASH_ENV") == Path.expand("../../priv/build_gate.bash", __DIR__) and
      Map.fetch!(values, "AIUR_BUILD_GATE_LEASE_PATH") == nil and
      Map.fetch!(values, "AIUR_BUILD_GATE_LEASE_TOKEN") == nil
  end
end
