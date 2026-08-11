defmodule Aiur.EngineCommandTestSupport do
  @engine Path.expand("../../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  def run_sourced_engine(script, env \\ []) do
    env =
      if List.keymember?(env, "AIUR_RELEASE_NODE", 0) do
        env
      else
        release_node = "aiur-enginetest-#{System.unique_integer([:positive])}@127.0.0.1"
        [{"AIUR_RELEASE_NODE", release_node} | env]
      end

    System.cmd("bash", ["-c", "set -euo pipefail\nsource \"$AIUR_ENGINE\"\n#{script}"],
      env: [{"AIUR_ENGINE", @engine} | env],
      stderr_to_stdout: true
    )
  end
end
