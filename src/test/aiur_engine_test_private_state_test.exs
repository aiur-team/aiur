defmodule AiurEngineTestPrivateStateTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  @ids "99,100,101"

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-test-private")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root}
  end

  defp sandbox_dir(root, name) do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    File.write!(Path.join(path, ".aiur-test-private"), "#{@ids}\n")
    File.write!(Path.join(path, "agent-token"), "secret\n")
    path
  end

  test "a sandbox daemon killed by signal leaves no aiur-test-* dir behind", %{root: root} do
    budget = sandbox_dir(root, "aiur-test-budget.sig")
    state = sandbox_dir(root, "aiur-test-state.sig")

    # A stand-in BEAM; killing it by PID is the stop path no `aiur stop` sees.
    script = """
    reap_aiur_agents() { :; }
    marker="aiur-private-beam-$$"
    bash -c "exec -a $marker sleep 30" & beam=$!
    for _ in $(seq 1 50); do pgrep -f -- "$marker" >/dev/null && break; sleep 0.05; done
    watchdog="$(start_beam_death_watchdog "$marker" sock pidfile 0.05 0)"
    sleep 0.2
    kill -TERM "$beam"
    for _ in $(seq 1 100); do [ -e "$AIUR_GITHUB_BUDGET_DIR" ] || [ -e "$AIUR_DEV_TEST_STATE_DIR" ] || break; sleep 0.05; done
    kill "$watchdog" 2>/dev/null || true
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_DEV_TEST_TICKET_IDS", @ids},
        {"AIUR_GITHUB_BUDGET_DIR", budget},
        {"AIUR_DEV_TEST_STATE_DIR", state}
      ])

    refute File.exists?(budget), out
    refute File.exists?(state), out
  end

  test "launch cleanup spares dirs another sandbox scope recorded", %{root: root} do
    other = sandbox_dir(root, "aiur-test-state.other")
    File.write!(Path.join(other, ".aiur-test-private"), "7\n")

    {_out, 0} =
      run_sourced_engine("cleanup_test_launch_private_state", [
        {"AIUR_DEV_TEST_TICKET_IDS", @ids},
        {"AIUR_DEV_TEST_STATE_DIR", other}
      ])

    assert File.exists?(Path.join(other, "agent-token"))
  end

  test "the next launch's sweep removes a stale aiur-test-* dir and keeps a fresh one", %{root: root} do
    stale = sandbox_dir(root, "aiur-test-budget.stale")
    fresh = sandbox_dir(root, "aiur-test-state.fresh")

    script = """
    OLD="$(date -d '2 days ago' +%Y%m%d%H%M 2>/dev/null || date -v-2d +%Y%m%d%H%M)"
    find "$STALE" -exec touch -t "$OLD" {} +
    TMPDIR="$T" XDG_RUNTIME_DIR="$T" sweep_stale_tmp_artifacts
    """

    {out, 0} = run_sourced_engine(script, [{"T", root}, {"STALE", stale}])

    refute File.exists?(stale), out
    assert File.exists?(Path.join(fresh, "agent-token"))
  end
end
