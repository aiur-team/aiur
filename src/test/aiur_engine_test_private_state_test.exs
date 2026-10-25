defmodule AiurEngineTestPrivateStateTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  @ids "99,100,101"

  # Logs every rm so a test can prove the token copy is removed before its dir.
  @rm_spy ~S"""
  rm() { printf 'RM:%s\n' "$*" >> "$EVENTS"; command rm "$@"; }
  """

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-test-private")
    File.mkdir_p!(root)
    events = Path.join(root, "events")
    File.write!(events, "")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root, events: events}
  end

  defp sandbox_dir(root, name, ids \\ @ids) do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    File.write!(Path.join(path, ".aiur-test-private"), "#{ids}\n")
    File.write!(Path.join(path, "agent-token"), "secret\n")
    path
  end

  defp launch_env(budget, state, extra \\ []) do
    [
      {"AIUR_DEV_TEST_TICKET_IDS", @ids},
      {"AIUR_GITHUB_BUDGET_DIR", budget},
      {"AIUR_DEV_TEST_STATE_DIR", state}
      | extra
    ]
  end

  defp assert_token_removed_first(events, dir) do
    lines = events |> File.read!() |> String.split("\n", trim: true)
    token = Enum.find_index(lines, &(&1 == "RM:-f -- #{dir}/agent-token"))
    tree = Enum.find_index(lines, &(&1 == "RM:-rf -- #{dir}"))
    assert token && tree && token < tree, "expected token removal before #{dir}:\n#{Enum.join(lines, "\n")}"
  end

  test "a sandbox daemon killed by signal leaves no aiur-test-* dir behind", %{root: root, events: events} do
    budget = sandbox_dir(root, "aiur-test-budget.sig")
    state = sandbox_dir(root, "aiur-test-state.sig")

    # A stand-in BEAM; killing it by PID is the stop path no `aiur stop` sees.
    script =
      @rm_spy <>
        """
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

    {out, 0} = run_sourced_engine(script, launch_env(budget, state, [{"EVENTS", events}]))

    refute File.exists?(budget), out
    refute File.exists?(state), out
    assert_token_removed_first(events, budget)
  end

  test "the foreground trap removes the dirs when the launcher gets SIGTERM", %{root: root, events: events} do
    budget = sandbox_dir(root, "aiur-test-budget.fg")
    state = sandbox_dir(root, "aiur-test-state.fg")

    script =
      @rm_spy <>
        """
        reap_aiur_agents() { :; }
        sweep_dead_tmux_sockets() { :; }
        sweep_stale_tmp_artifacts() { :; }
        aiur_instance_record_path() { printf '%s' "$RECORD"; }
        install_foreground_traps
        kill -TERM $$
        sleep 5
        """

    {out, code} =
      run_sourced_engine(
        script,
        launch_env(budget, state, [{"EVENTS", events}, {"RECORD", Path.join(root, "record")}])
      )

    assert code == 143, out
    refute File.exists?(budget), out
    refute File.exists?(state), out
    assert_token_removed_first(events, budget)
  end

  test "the next launch removes a SIGKILLed sandbox's dirs regardless of age", %{root: root, events: events} do
    orphan = sandbox_dir(root, "aiur-test-budget.orphan")
    live_launcher = sandbox_dir(root, "aiur-test-state.launcher")
    held = sandbox_dir(root, "aiur-test-budget.held")
    unmarked = Path.join(root, "aiur-test-state.unmarked")
    File.mkdir_p!(unmarked)

    script =
      @rm_spy <>
        """
        sleep 0 & dead=$!; wait "$dead"
        printf '%s\\n' "$dead" >"$ORPHAN/.aiur-test-launcher"
        sleep 30 & alive=$!
        printf '%s\\n' "$alive" >"$LIVE/.aiur-test-launcher"
        env AIUR_GITHUB_BUDGET_DIR="$HELD" sleep 30 & holder=$!
        sleep 0.2
        sweep_orphan_test_private_dirs
        kill "$alive" "$holder" 2>/dev/null || true
        """

    {out, 0} =
      run_sourced_engine(script, [
        {"EVENTS", events},
        {"TMPDIR", root},
        {"ORPHAN", orphan},
        {"LIVE", live_launcher},
        {"HELD", held},
        {"AIUR_GITHUB_BUDGET_DIR", nil},
        {"AIUR_DEV_TEST_STATE_DIR", nil}
      ])

    refute File.exists?(orphan), out
    assert_token_removed_first(events, orphan)
    assert File.exists?(Path.join(live_launcher, "agent-token")), "live launcher's dir must survive"
    assert File.exists?(Path.join(held, "agent-token")), "dir named by a live process env must survive"
    assert File.dir?(unmarked)
  end

  test "launch cleanup removes only the dirs this scope recorded", %{root: root} do
    mine = sandbox_dir(root, "aiur-test-state.mine")
    other = sandbox_dir(root, "aiur-test-budget.other", "7")

    {out, 0} = run_sourced_engine("cleanup_test_launch_private_state", launch_env(other, mine))

    refute File.exists?(mine), out
    assert File.exists?(Path.join(other, "agent-token"))
  end

  test "the age-gated sweep removes a stale aiur-test-* dir and keeps a fresh one", %{root: root} do
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
