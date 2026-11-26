defmodule Aiur.Regression.OrchestratorBlockingHttp.ControlQueriesTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorBlockingHttpSupport
  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI
  alias Aiur.Orchestrator.SnapshotStore

  @cli_budget_ms 5_000

  setup do
    setup_orchestrator()
  end

  describe "control queries while the orchestrator holds a GitHub read" do
    setup %{orchestrator: pid} do
      :ok = publish_current_view(pid)
      on_exit(fn -> SnapshotStore.forget(Orchestrator) end)

      # Registered first so it runs last: the shared Orchestrator must be
      # answering again before any later cleanup tries to talk to it.
      on_exit(fn -> wait_until(fn -> answers?(pid) end, 400) end)

      url = hanging_endpoint()
      test_pid = self()

      # Run the hanging GitHub read *on the Orchestrator process itself*, which
      # is exactly what the captured stack showed. `:sys.replace_state/3`
      # evaluates the function inside the target process.
      blocker =
        spawn(fn ->
          :sys.replace_state(
            pid,
            fn state ->
              send(test_pid, :fetch_started)
              hanging_request(url)
              state
            end,
            :infinity
          )
        end)

      on_exit(fn -> if Process.alive?(blocker), do: Process.exit(blocker, :kill) end)

      assert_receive :fetch_started, 5_000
      refute_eventually_answers(pid)

      :ok
    end

    test "status answers inside the CLI budget", %{orchestrator: pid} do
      {elapsed_us, output} = :timer.tc(fn -> capture_io(fn -> AgentControlCLI.status() end) end)

      assert_blocked(pid)
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
      refute output =~ "__AIUR_CONTROL_ERROR__"
      assert div(elapsed_us, 1_000) < @cli_budget_ms
    end

    test "agents answers inside the CLI budget", %{orchestrator: pid} do
      {elapsed_us, output} = :timer.tc(fn -> capture_io(fn -> AgentControlCLI.agents() end) end)

      assert_blocked(pid)
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
      refute output =~ "__AIUR_CONTROL_ERROR__"
      assert div(elapsed_us, 1_000) < @cli_budget_ms
    end

    # Named for what it proves. It does *not* show that the mailbox stays flat
    # while a fetch is outstanding — it cannot: the Orchestrator is still parked
    # in a receive here, so anything else that messages it does queue. What it
    # shows is narrower and is the property the control-query change bought:
    # these forty queries are not among the things that queue.
    test "control queries add nothing to the orchestrator mailbox", %{orchestrator: pid} do
      # The shared global Orchestrator's absolute mailbox depth is not a stable
      # assertion under CI: async test modules running in the same partition
      # legitimately send it messages, so the depth can grow while these
      # queries are themselves innocent (the #1920 flake observed 3..4 vs 1).
      # What this test owns is its own process's traffic, so that is exactly
      # what it asserts: trace sends *to the orchestrator from this process*
      # and require the forty control queries to add none. Reads from the
      # SnapshotStore read model never message the Orchestrator, so any send
      # from this process would be a real regression of the #1837 property.
      me = self()
      :erlang.trace(pid, true, [:send])

      on_exit(fn -> :erlang.trace(pid, false, [:send]) end)

      before = sends_from_self(pid, me)

      for _repeat <- 1..20 do
        capture_io(fn -> AgentControlCLI.status() end)
        capture_io(fn -> AgentControlCLI.agents() end)
      end

      # Not "grows slowly" — flat. Forty control queries send this process
      # nothing to the orchestrator, because none of them message it.
      assert sends_from_self(pid, me) == before
    end

    test "the orchestrator is not inside a GitHub read on its own process", %{orchestrator: pid} do
      # Sampled repeatedly for the same reason as the caller-side assertion: one
      # sample can land between connect and recv and miss the frames entirely.
      # This is the assertion that guards the exact stack #1837 reported, so it
      # is the last one that should be decided by a single look.
      for _sample <- 1..20 do
        assert http_client_frames(pid) == [],
               "the orchestrator is holding the socket: #{inspect(Process.info(pid, :current_stacktrace))}"

        Process.sleep(50)
      end
    end
  end

  # #2329: `aiurdev resume <id>` timed out with "timed out while reading agent
  # status" on max_agent_duration pauses while `status` answered from the read
  # model in ~300ms. The resume command was still reading its target view from
  # the Orchestrator mailbox (`Orchestrator.status/0`), so it queued behind a
  # blocked GitHub read. It must read the same SnapshotStore read model the
  # read-only commands use, so a resume never depends on a busy or dead agent
  # process answering a status read.
  describe "resume while the orchestrator holds a GitHub read" do
    setup %{orchestrator: pid} do
      # Publish a view that already contains a paused duration-capped agent so
      # the read model can serve the resume's target row while the Orchestrator
      # is parked in a GitHub read. The entry must be injected before the block:
      # `:sys.replace_state` after the block would wait on the parked process.
      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-44" => paused_duration_entry("issue-44", "44")}}
      end)

      :ok = publish_current_view(pid)
      on_exit(fn -> SnapshotStore.forget(Orchestrator) end)

      # Registered first so it runs last: the shared Orchestrator must be
      # answering again before any later cleanup tries to talk to it.
      on_exit(fn -> wait_until(fn -> answers?(pid) end, 400) end)

      url = hanging_endpoint()
      test_pid = self()

      blocker =
        spawn(fn ->
          :sys.replace_state(
            pid,
            fn state ->
              send(test_pid, :fetch_started)
              hanging_request(url)
              state
            end,
            :infinity
          )
        end)

      on_exit(fn -> if Process.alive?(blocker), do: Process.exit(blocker, :kill) end)

      assert_receive :fetch_started, 5_000
      refute_eventually_answers(pid)

      :ok
    end

    test "resume reads its target view from the read model, not the mailbox", %{orchestrator: pid} do
      {_elapsed_us, output} = :timer.tc(fn -> capture_io(fn -> AgentControlCLI.resume(["44"]) end) end)

      assert_blocked(pid)

      # The status read that produced #2329's error is served from the read
      # model now, so the resume gets past target selection. With the
      # Orchestrator fully parked in a GitHub read, the resume RPC itself
      # cannot be answered — that failure is reported at the RPC, not as a
      # status-read timeout.
      refute output =~ "timed out while reading agent status"
      assert output =~ "outcome unknown for resume #44"
      refute output =~ "failed to resume"
      assert output =~ "__AIUR_CONTROL_EXIT__:124"
    end
  end

  test "a fleet view behind its producer is rendered with its age, not as current", %{orchestrator: pid} do
    previous_ceiling = Application.get_env(:aiur, :snapshot_stale_age_ceiling_ms)
    Application.put_env(:aiur, :snapshot_stale_age_ceiling_ms, 50)
    on_exit(fn -> restore_application_env(:snapshot_stale_age_ceiling_ms, previous_ceiling) end)

    :ok = publish_current_view(pid)
    on_exit(fn -> SnapshotStore.forget(Orchestrator) end)
    Process.sleep(120)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "STALE FLEET VIEW — showing the last-known-good snapshot,"
    assert output =~ "old (the orchestrator has stopped publishing)"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end
end
