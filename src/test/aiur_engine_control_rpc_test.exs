defmodule AiurEngineControlRpcTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "todo control rpc propagates live success and semantic failure codes" do
    for {rpc_output, expected_code} <- [
          {"queued 1 ticket(s); cleared 0 other(s)\n__AIUR_CONTROL_EXIT__:0", 0},
          {"queued 0 ticket(s); cleared 0 other(s)\n__AIUR_CONTROL_EXIT__:1", 1}
        ] do
      script = """
      resolve_release() { release_bin="/bin/true"; release_dir="/tmp"; vsn_dir="/tmp"; RELEASE_NODE="aiur-test@127.0.0.1"; }
      prepare_distribution() { :; }
      resolve_control_identity_from_records() { :; }
      probe_node_liveness() { printf up; }
      run_release_rpc_with_timeout() {
        AIUR_CONTROL_RPC_OUTPUT='#{rpc_output}'
        AIUR_CONTROL_RPC_TIMED_OUT=0
        return 0
      }
      code=0
      run_todo --todo 123 || code=$?
      echo "CODE=$code"
      """

      {out, 0} = run_sourced_engine(script, [])

      assert out =~ "CODE=#{expected_code}"
      assert out =~ "queued"
      refute out =~ "returned no exit marker"
    end
  end

  test "control rpc reports timeouts and missing exit markers instead of silently succeeding" do
    base = """
    resolve_release() { release_bin="/bin/true"; release_dir="/tmp"; vsn_dir="/tmp"; RELEASE_NODE="aiur-test@127.0.0.1"; }
    prepare_distribution() { :; }
    resolve_control_identity_from_records() { :; }
    probe_node_liveness() { printf up; }
    """

    timeout_script =
      base <>
        """
        run_release_rpc_with_timeout() {
          AIUR_CONTROL_RPC_OUTPUT=''
          AIUR_CONTROL_RPC_TIMED_OUT=1
          return 124
        }
        code=0
        run_control_rpc "Aiur.AgentControlCLI.resume([\"44\"])" || code=$?
        echo "CODE=$code"
        """

    {timeout_output, 0} = run_sourced_engine(timeout_script, [])
    assert timeout_output =~ "control rpc to aiur-test@127.0.0.1 timed out after 10s; outcome is unknown"
    refute timeout_output =~ "scheduler-saturated"
    refute timeout_output =~ "aiurdev stop"
    assert timeout_output =~ "CODE=124"

    missing_marker_script =
      base <>
        """
        run_release_rpc_with_timeout() {
          AIUR_CONTROL_RPC_OUTPUT=''
          AIUR_CONTROL_RPC_TIMED_OUT=0
          return 0
        }
        code=0
        run_control_rpc "Aiur.AgentControlCLI.resume([\"44\"])" || code=$?
        echo "CODE=$code"
        """

    {missing_marker_output, 0} = run_sourced_engine(missing_marker_script, [])
    assert missing_marker_output =~ "returned no exit marker; command output may be incomplete"
    assert missing_marker_output =~ "CODE=1"
  end

  test "streaming control rpc reports a stopped daemon" do
    rel = fake_release()
    state = tmp_state()

    {out, 1} =
      run_sourced_engine(
        ~S|resolve_release() { release_bin="/bin/false"; RELEASE_NODE="aiur-test@127.0.0.1"; }; prepare_distribution() { :; }; resolve_control_identity_from_records() { :; }; probe_node_liveness() { printf down; }; run_control_stream 'Aiur.AgentControlCLI.executor_listen()'|,
        [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}]
      )

    assert out =~ "error: aiur is not running. Start it with `aiurdev run` (or `aiurdev --bg`), then retry."
    refute out =~ "GenServer"
  end

  test "listen validates through daemon, supports alias, and rejects widening patterns" do
    {ticket, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "VALIDATE:$1"; return 0; }
run_control_stream() { echo "STREAM:$1"; return 0; }
aiur_engine_main listen --ticket 3028|,
        []
      )

    assert ticket =~ ~s|executor_listen_validate(Base.decode64!("dGlja2V0LjMwMjguIw=="))|
    assert ticket =~ ~s|executor_listen(topic: Base.decode64!("dGlja2V0LjMwMjguIw=="))|

    {alias_output, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { return 0; }
run_control_stream() { echo "STREAM:$1"; return 0; }
aiur_engine_main executor-listen --topic 'ticket.3028.#'|,
        []
      )

    assert alias_output =~ "executor_listen(topic:"

    {widened, 64} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "$1"; echo 'aiur: listen topic rejected (:binding_not_allowlisted); allowed bindings: executor.#, ticket.*.ci.passed'; return 64; }
run_control_stream() { echo SHOULD_NOT_STREAM; return 0; }
aiur_engine_main listen --topic 'ticket.*.#'|,
        []
      )

    assert widened =~ "executor_listen_validate"
    assert widened =~ "ticket.*.ci.passed"
    refute widened =~ "SHOULD_NOT_STREAM"
  end

  test "listen backs off for about ten minutes of one outage, then stops" do
    {out, 1} =
      run_sourced_engine(
        ~s|run_control_rpc() { return 0; }
run_control_stream() { echo ATTEMPT; return 1; }
sleep() { echo "SLEEP:$1"; }
aiur_engine_main listen --ticket 3028|,
        []
      )

    delays = ~r/SLEEP:(\d+)/ |> Regex.scan(out) |> Enum.map(fn [_, d] -> String.to_integer(d) end)
    assert Enum.take(delays, 7) == [2, 4, 8, 16, 32, 60, 60], out
    assert Enum.sum(delays) in 600..660, out
    assert out =~ "could not reconnect within"
  end

  test "listen resets its outage budget after a stream that stayed connected" do
    # Each stream lasts 40s before the daemon drops it; 30 such drops far exceed
    # one outage budget, so only a per-connection reset reaches the clean exit.
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { return 0; }
state="$(mktemp -d)"; echo 0 > "$state/streams"; echo 0 > "$state/clock"
listen_clock() { cat "$state/clock"; }
run_control_stream() { n=$(( $(cat "$state/streams") + 1 )); echo "$n" > "$state/streams"; echo $(( $(cat "$state/clock") + 40 )) > "$state/clock"; [ "$n" -ge 30 ] && return 0; return 1; }
sleep() { echo "SLEEP:$1"; }
aiur_engine_main listen --ticket 3028; rc=$?; rm -rf "$state"; exit "$rc"|,
        []
      )

    delays = ~r/SLEEP:(\d+)/ |> Regex.scan(out) |> Enum.map(fn [_, d] -> String.to_integer(d) end)
    assert delays == List.duplicate(2, 29), out
    refute out =~ "could not reconnect"
  end

  test "listen retries when an attempt dies, as during an in-place dev rebuild" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { return 0; }
marker="$(mktemp)"; rm -f "$marker"
run_control_stream() { [ -e "$marker" ] && return 0; touch "$marker"; die "AIUR_RELEASE_DIR does not exist: /gone"; }
sleep() { echo "SLEEP:$1"; }
aiur_engine_main listen --ticket 3028; rc=$?; rm -f "$marker"; exit "$rc"|,
        []
      )

    assert out =~ "AIUR_RELEASE_DIR does not exist"
    assert out =~ "SLEEP:2", out
  end

  test "listen stops without retrying on a stream exit status other than 1" do
    {out, 2} =
      run_sourced_engine(
        ~s|run_control_rpc() { return 0; }
run_control_stream() { echo ATTEMPT; return 2; }
sleep() { echo SLEPT; }
aiur_engine_main listen --ticket 3028|,
        []
      )

    assert length(Regex.scan(~r/ATTEMPT/, out)) == 1, out
    refute out =~ "SLEPT"
    assert out =~ "listen stopped after streaming control RPC failure (exit 2)"
  end

  test "executor-wait dispatches a bounded RPC and validates timeout usage" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "TIMEOUT:$AIUR_CONTROL_RPC_TIMEOUT_SECONDS"; echo "RPC:$1"; }
cmd_executor_wait --timeout 2 --json|,
        []
      )

    assert out =~ "TIMEOUT:12"
    assert out =~ "Aiur.AgentControlCLI.executor_wait(timeout_ms: 2000, json: true)"

    {bad, 64} = run_sourced_engine("cmd_executor_wait --timeout nope", [])
    assert bad =~ "executor-wait --timeout expects a positive integer"
  end

  test "the takeover commands pass an explicit consumer id and nothing else" do
    {wait, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }
cmd_executor_wait --timeout 2 --as agent-b|,
        []
      )

    assert wait =~ ~s|executor_wait(timeout_ms: 2000, json: false, as: "agent-b")|

    {claim, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_executor_claim --as agent-a|, [])
    assert claim =~ ~s|executor_claim([as: "agent-a"])|

    {release, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_executor_release|, [])
    assert release =~ "executor_release([])"

    {revoke, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_executor_revoke agent-a|, [])
    assert revoke =~ ~s|executor_revoke("agent-a")|

    {roster, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_executor_roster --json|, [])
    assert roster =~ "executor_roster(json: true)"

    {fast_forward, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }
aiur_engine_main executor-fast-forward 2832 --as agent-a|,
        []
      )

    assert fast_forward =~ ~s|executor_fast_forward(2832, [as: "agent-a"])|

    # A revoke must name the owner: the operator decides, so there is no
    # "revoke whoever holds it" form.
    {missing, 64} = run_sourced_engine("cmd_executor_revoke", [])
    assert missing =~ "executor-revoke requires the current owner's consumer id"

    {bad_id, 64} = run_sourced_engine("cmd_executor_claim --as 'not a/id'", [])
    assert bad_id =~ "executor-claim --as expects"

    {bad_wake_id, 64} = run_sourced_engine("cmd_executor_fast_forward nope", [])
    assert bad_wake_id =~ "executor-fast-forward expects a positive wake id"

    {missing_as, 64} = run_sourced_engine("cmd_executor_fast_forward 2832 --as", [])
    assert missing_as =~ "executor-fast-forward --as requires a consumer id"

    {empty_as, 64} = run_sourced_engine("cmd_executor_fast_forward 2832 --as=", [])
    assert empty_as =~ "executor-fast-forward --as requires a consumer id"
  end

  test "streaming control rpc preserves an unexpected crash marker" do
    marker = Aiur.TestSupport.tmp_root!("aiur-stream-crash")
    File.write!(marker, "reason=boom\n")

    {out, 1} =
      run_sourced_engine(
        ~S|resolve_release() { release_bin="/bin/false"; RELEASE_NODE="aiur-test@127.0.0.1"; }; prepare_distribution() { :; }; resolve_control_identity_from_records() { :; }; probe_node_liveness() { printf down; }; aiur_crash_marker_path() { printf '%s' "$CRASH_MARKER"; }; run_control_stream 'Aiur.AgentControlCLI.executor_listen()'|,
        [{"CRASH_MARKER", marker}]
      )

    assert out =~ "aiur: background daemon"
    assert out =~ "reason=boom"
    refute out =~ "error: aiur is not running"
  end

  test "findings boots distribution-free without requiring a running node" do
    rel = fake_release()
    state = Aiur.TestSupport.tmp_root!("aiur-st")

    {out, _} = run_engine(["findings", "--slugs"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])

    assert out =~ "ELIXIR_ARGS:"
    assert out =~ "Aiur.CLI.main(Aiur.CLI.argv_from_file())"
    refute out =~ "--name"
    refute out =~ "BIN:"
  end

  test "ask boots distribution-free without requiring a running node" do
    rel = fake_release()
    state = Aiur.TestSupport.tmp_root!("aiur-st")

    {out, _} = run_engine(["ask", "Enable CI readiness", "--blocking"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])

    assert out =~ "ELIXIR_ARGS:"
    assert out =~ "Aiur.CLI.main(Aiur.CLI.argv_from_file())"
    refute out =~ "--name"
    refute out =~ "BIN:"
  end

  test "todo without IDs exits 64 before resolving a release" do
    {out, code} = run_engine(["--todo"], [])
    assert code == 64
    assert out =~ "--todo expects one or more numeric issue IDs"
  end

  test "todo rejects nonnumeric IDs" do
    {out, code} = run_engine(["--todo", "11", "nope"], [])
    assert code == 64
    assert out =~ "--todo expects one or more numeric issue IDs"
  end

  test "only without todo exits 64" do
    {out, code} = run_engine(["--only"], [])
    assert code == 64
    assert out =~ "--only is valid only with --todo"
  end

  # Lifecycle commands generate + validate a cookie, whose owner must equal
  # $USER, so these run as the real user (only the state dir is redirected).

  # Bare `pause`/`resume` used to be a usage error. It is now the global switch,
  # so only *malformed* targets still earn exit 64.
  test "pause with malformed targets exits 64 with guidance" do
    {out, code} = run_engine_real(["pause", "not-an-id"], [{"AIUR_RELEASE_DIR", fake_release()}])
    assert code == 64
    assert out =~ "expects issue IDs or --all"
    assert out =~ "bare aiur pause for the global switch"
  end

  test "bare pause/resume RPC the global switch into the node" do
    rel = fake_release()
    state = tmp_state()

    {paused, _} = run_engine_real(["pause"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])
    assert paused =~ "Aiur.AgentControlCLI.pause_global()"

    {resumed, _} = run_engine_real(["resume"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])
    assert resumed =~ "Aiur.AgentControlCLI.resume_global()"
  end

  test "pause/resume RPC the AgentControlCLI expression into the node" do
    rel = fake_release()
    state = tmp_state()

    {paused, _} = run_engine_real(["pause", "44,45"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])
    assert paused =~ ~s|Aiur.AgentControlCLI.pause(["44", "45"])|

    {resumed, _} = run_engine_real(["resume", "--all"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])
    assert resumed =~ "Aiur.AgentControlCLI.resume(:all)"
  end

  test "reset-budget --all exits 64 with guidance instead of silently no-opping" do
    # #1453 review P2d: `parse_issue_targets` accepts `--all` (empty targets),
    # and the original cmd_reset_budget proceeded to reset_budget([]) → exit 0
    # no-op. The command must reject --all loudly so an operator never believes
    # the whole board was reset.
    rel = fake_release()
    {out, code} = run_engine(["reset-budget", "--all"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}])
    assert code == 64
    assert out =~ "reset-budget does not accept --all"
    assert out =~ "name ticket IDs explicitly"
  end

  test "reset-budget with non-numeric targets exits 64" do
    rel = fake_release()
    {out, code} = run_engine(["reset-budget", "not-an-id"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}])
    assert code == 64
    assert out =~ "reset-budget expects issue IDs"
  end

  test "usage RPCs the usage expression" do
    rel = fake_release()
    {out, _} = run_engine_real(["usage"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}])
    assert out =~ "Aiur.AgentControlCLI.usage()"
  end

  test "usage rejects arguments" do
    {out, code} = run_engine_real(["usage", "codex"], [{"AIUR_RELEASE_DIR", fake_release()}])
    assert code != 0
    assert out =~ "usage does not accept arguments"
  end

  test "accounts uses daemon control RPC when the daemon is reachable" do
    {out, 0} =
      run_sourced_engine(
        ~S|resolve_release() { :; }; prepare_distribution() { :; }; resolve_control_identity_from_records() { :; }; probe_node_liveness() { printf up; }; run_control_rpc() { printf 'RPC:%s\n' "$1"; }; run_local_cli() { printf 'LOCAL:%s\n' "$*"; }; cmd_accounts --json|,
        []
      )

    assert out =~ "RPC:Aiur.AgentControlCLI.accounts(true)"
    refute out =~ "LOCAL:"
  end

  test "accounts falls back to local identity rendering when the daemon is down" do
    {out, 0} =
      run_sourced_engine(
        ~S|resolve_release() { :; }; prepare_distribution() { :; }; resolve_control_identity_from_records() { :; }; probe_node_liveness() { printf down; }; run_control_rpc() { printf 'RPC:%s\n' "$1"; }; run_local_cli() { printf 'LOCAL:%s\n' "$*"; }; cmd_accounts --json|,
        []
      )

    assert out =~ "LOCAL:accounts --json"
    refute out =~ "RPC:"
  end

  test "accounts preserves the requested harness through daemon control RPC" do
    {out, 0} =
      run_sourced_engine(
        ~S|resolve_release() { :; }; prepare_distribution() { :; }; resolve_control_identity_from_records() { :; }; probe_node_liveness() { printf up; }; run_control_rpc() { printf 'RPC:%s\n' "$1"; }; cmd_accounts codex --json|,
        []
      )

    assert out =~ ~s|RPC:Aiur.AgentControlCLI.accounts(true, Base.decode64!("Y29kZXg="))|
  end

  test "status RPCs the status expression" do
    rel = fake_release()
    {out, _} = run_engine_real(["status"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}])
    assert out =~ "Aiur.AgentControlCLI.status()"
  end
end
