# Research-only: compile frozen monitor sources in an isolated VM.
# Usage: ERL_FLAGS='+S 1:1' elixir disabled_monitor_init_probe.exs SNAPSHOT_ROOT
# Config doubles force the disabled branches; this does not boot Aiur.
[root] = System.argv()
defmodule Aiur.BuildGate do
  def enabled?, do: false
end
defmodule Aiur.Config do
  def saturation_log_enabled?, do: false
end
Code.compiler_options(ignore_module_conflict: true, no_warn_undefined: :all)
IO.puts("Elixir=#{System.version()} OTP=#{System.otp_release()}")
for {module, file} <- [
  {Aiur.BuildGateHoldMonitor, "src/lib/aiur/build_gate_hold_monitor.ex"},
  {Aiur.SaturationSentinel, "src/lib/aiur/saturation_sentinel.ex"}
] do
  source = File.read!(Path.join(root, file))
  Code.compile_string(source, file)
  original = GenServer.start(module, [])
  {:error, {:bad_return_value, {:ignore, state}}} = original
  true = is_struct(state)
  IO.puts("#{inspect(module)} original=bad_return_value")
  corrected = String.replace(source, "{:ignore, %State{}}", ":ignore")
  true = corrected != source
  Code.compile_string(corrected, file)
  :ignore = GenServer.start(module, [])
  IO.puts("#{inspect(module)} in_memory_correction=ignore")
end
