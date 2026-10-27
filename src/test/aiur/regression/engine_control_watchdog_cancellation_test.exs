defmodule Aiur.Regression.EngineControlWatchdogCancellationTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  # Future regression guard: cancellation already exists; fixture startup was broken in #5027.
  @tag timeout: 15_000
  test "a successful RPC cancels and reaps its armed watchdog before returning" do
    rel = fake_release()
    state = tmp_state()
    File.mkdir_p!(state)
    ready = Path.join(state, "ready")
    assert {"", 0} = System.cmd("mkfifo", [ready])

    File.write!(Path.join([rel, "bin", "aiur"]), """
    #!/usr/bin/env bash
    read -r ready < "$READY_PIPE"
    echo '__AIUR_CONTROL_EXIT__:0'
    """)

    File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(state) end)

    {out, 0} =
      run_sourced_engine(
        ~S"""
        sleep() {
          echo "$BASHPID" > "$WATCHDOG_PID"
          command sleep "$@" &
          child=$!
          echo "$child" > "$SLEEP_PID"
          printf 'ready\n' > "$READY_PIPE"
          wait "$child"
        }
        run_control_rpc 'Aiur.AgentControlCLI.status()'
        for file in "$WATCHDOG_PID" "$SLEEP_PID"; do
          pid="$(cat "$file")"
          if kill -0 "$pid" 2>/dev/null; then
            echo "SURVIVOR:$pid"
            kill -KILL "$pid" 2>/dev/null || true
            exit 1
          fi
        done
        echo CANCELLED
        """,
        [
          {"AIUR_RELEASE_DIR", rel},
          {"AIUR_BG_STATE_DIR", state},
          {"AIUR_CONTROL_RPC_TIMEOUT_SECONDS", "120"},
          {"READY_PIPE", ready},
          {"WATCHDOG_PID", Path.join(state, "watchdog.pid")},
          {"SLEEP_PID", Path.join(state, "sleep.pid")}
        ]
      )

    assert out == "CANCELLED\n"
  end
end
