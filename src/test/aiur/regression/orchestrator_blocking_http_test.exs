defmodule Aiur.Regression.OrchestratorBlockingHttpTest do
  @moduledoc """
  #1837 — the Orchestrator was captured blocked in `:gen.do_call/4` inside
  `Mint.Core.Transport.SSL.recv/3`: 60/60 samples `:waiting`, mailbox climbing
  6,034 → 6,116 in three seconds, `run_queue` 0. One process holding a socket,
  not a busy host. `aiur status` timed out at 5.5s and `aiur agents` at 6.4s
  while `aiur alerts` — which never touches the Orchestrator — answered in
  ~300ms.

  Two independent guarantees are asserted here, because either one alone leaves
  the operator surface broken:

    1. A hanging GitHub response does not park the calling process inside the
       HTTP client stack. The socket belongs to a task that can be abandoned.
    2. `status` and `agents` are answered from the snapshot read model, so they
       cannot queue behind whatever the dispatch loop is doing — and when that
       read model is behind, they say so with its age rather than rendering a
       stale fleet as current.
  """

  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI
  alias Aiur.GitHub.Transport
  alias Aiur.Orchestrator.CommentPolling
  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.Orchestrator.StatusReport

  # `@status_timeout_ms` in `Aiur.AgentControlCLI`. A control query that reads
  # already-known state must finish well inside it.
  @cli_budget_ms 5_000

  setup do
    pid = Process.whereis(Orchestrator)
    original_state = :sys.get_state(pid)
    previous_health_fun = Application.get_env(:aiur, :supervision_health_status_fun)
    previous_deadline = Application.get_env(:aiur, :github_request_deadline_ms)

    Application.put_env(:aiur, :supervision_health_status_fun, fn -> {:ok, %{expected: 2, healthy: 2, missing: []}} end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{}, last_polled_issues: %{}, session_max_concurrent_agents: nil}
    end)

    on_exit(fn ->
      restore_application_env(:supervision_health_status_fun, previous_health_fun)
      restore_application_env(:github_request_deadline_ms, previous_deadline)

      if Process.alive?(pid) do
        :sys.replace_state(pid, fn _state -> original_state end)
      end
    end)

    {:ok, orchestrator: pid}
  end

  describe "a hanging GitHub response" do
    test "does not park the requesting process inside the HTTP client stack" do
      url = hanging_endpoint()
      test_pid = self()

      runner =
        spawn(fn ->
          send(test_pid, :request_issued)
          send(test_pid, {:request_finished, hanging_request(url)})
        end)

      on_exit(fn -> if Process.alive?(runner), do: Process.exit(runner, :kill) end)

      assert_receive :request_issued, 2_000
      wait_until_waiting(runner)

      # The measurement from the capture: which module is this process parked
      # in? A process that owns the socket is inside Mint/Finch/Req or the
      # transport primitives underneath them. Sampled repeatedly, because a
      # single sample can catch the process between connect and recv and miss
      # the frames entirely.
      for _sample <- 1..20 do
        assert http_client_frames(runner) == [],
               "the requesting process is holding the socket: #{inspect(Process.info(runner, :current_stacktrace))}"

        Process.sleep(50)
      end
    end

    test "is abandoned at its process deadline instead of wedging the caller" do
      Application.put_env(:aiur, :github_request_deadline_ms, 300)

      url = hanging_endpoint()
      test_pid = self()

      runner = spawn(fn -> send(test_pid, {:request_finished, hanging_request(url)}) end)
      on_exit(fn -> if Process.alive?(runner), do: Process.exit(runner, :kill) end)

      assert_receive {:request_finished, {:error, :fetch_deadline_exceeded}}, 2_000
    end
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
      before_depth = mailbox_depth(pid)

      for _repeat <- 1..20 do
        capture_io(fn -> AgentControlCLI.status() end)
        capture_io(fn -> AgentControlCLI.agents() end)
      end

      # Not "grows slowly" — flat. Forty control queries put nothing in the
      # mailbox, because none of them send it a message.
      assert mailbox_depth(pid) == before_depth
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

  describe "the comment poll fan-out" do
    # The second capture on #1837, and a different call site from the reported
    # one: host load 1.68, quota healthy, and the Orchestrator parked in
    # `Task.Supervised.stream_reduce/7` under `Dispatcher.do_maybe_dispatch/1`
    # with a 5,729-message mailbox while `status` and `agents` timed out. A
    # per-request deadline cannot bound an awaited fan-out — N targets cost N
    # deadlines — so the poll has to leave the callback altogether.
    test "is issued, not awaited, by the process that starts it" do
      test_pid = self()

      hanging_fetcher = fn _states ->
        send(test_pid, :comment_poll_started)
        Process.sleep(:infinity)
      end

      state = %Aiur.Orchestrator.State{running: %{}}

      {elapsed_us, next_state} =
        :timer.tc(fn ->
          CommentPolling.start_async(state, comment_poll_opts(hanging_fetcher))
        end)

      assert_receive :comment_poll_started, 5_000
      assert div(elapsed_us, 1_000) < 1_000
      assert %{ref: ref} = next_state.github_comment_poll
      assert is_reference(ref)
    end

    test "does not start a second poll while one is outstanding" do
      test_pid = self()

      hanging_fetcher = fn _states ->
        send(test_pid, :comment_poll_started)
        Process.sleep(:infinity)
      end

      opts = comment_poll_opts(hanging_fetcher)

      state = CommentPolling.start_async(%Aiur.Orchestrator.State{running: %{}}, opts)
      assert_receive :comment_poll_started, 5_000

      assert CommentPolling.start_async(state, opts).github_comment_poll == state.github_comment_poll
      refute_receive :comment_poll_started, 500
    end

    test "terminates an expired poll before starting its replacement" do
      test_pid = self()

      hanging_fetcher = fn _states ->
        send(test_pid, {:comment_poll_started, self()})
        Process.sleep(:infinity)
      end

      opts = comment_poll_opts(hanging_fetcher)

      state = CommentPolling.start_async(%Aiur.Orchestrator.State{running: %{}}, opts)
      assert_receive {:comment_poll_started, first_pid}, 5_000

      expired_at = System.monotonic_time(:millisecond) - 180_001
      expired_state = put_in(state.github_comment_poll.started_at_ms, expired_at)
      next_state = CommentPolling.start_async(expired_state, opts)

      wait_until(fn -> not Process.alive?(first_pid) end)
      assert_receive {:comment_poll_started, second_pid}, 5_000
      assert second_pid != first_pid
      assert next_state.github_comment_poll.pid == second_pid
    end

    test "drops a straggler from a poll the state is no longer waiting for" do
      state = %Aiur.Orchestrator.State{running: %{}, github_comments_since: %{"57" => "2026-06-24T11:00:00Z"}}

      assert CommentPolling.apply_async(state, make_ref(), {:error, :boom}) == state
    end
  end

  # The Orchestrator does still wait for its own GitHub reads — that wait is now
  # bounded, and bounded much nearer the operator's 5s control budget than the
  # general backstop, because everything else in its mailbox waits with it.
  test "an orchestrator-issued read is bounded near the control budget", %{orchestrator: pid} do
    request = %{method: :get, url: "https://api.github.com/rate_limit", token: "test-token", timeout_ms: 30_000}

    caller_deadline_ms = Transport.request_deadline_ms(request)
    orchestrator_deadline_ms = eval_on_orchestrator(pid, fn -> Transport.request_deadline_ms(request) end)

    assert orchestrator_deadline_ms < caller_deadline_ms
    assert orchestrator_deadline_ms <= 3 * @cli_budget_ms
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

  # The tracker gate is what this file cannot arrange from the shared workflow
  # file, so it is stated here; the property under test is the fan-out, not the
  # gate in front of it.
  defp comment_poll_opts(review_issue_fetcher) do
    [tracker_kind: "github", repo: "owner/repo", review_issue_fetcher: review_issue_fetcher]
  end

  # `:sys.replace_state/2` evaluates its function inside the target process, so
  # this answers "what does this code see when it runs on the Orchestrator?".
  defp eval_on_orchestrator(pid, fun) do
    test_pid = self()

    :sys.replace_state(pid, fn state ->
      send(test_pid, {:eval_result, fun.()})
      state
    end)

    receive do
      {:eval_result, value} -> value
    after
      5_000 -> flunk("the orchestrator never evaluated the probe")
    end
  end

  # The read model retains the projection its rows are built from, so a test
  # publishing a view has to hand over both.
  defp publish_current_view(pid) do
    state = :sys.get_state(pid)
    SnapshotStore.publish(Orchestrator, StatusReport.snapshot_payload(state), state)
  end

  # A listener that completes the TCP handshake and then never answers — the
  # slow-peer shape that leaves a client parked in `recv`.
  defp hanging_endpoint do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    accepter =
      spawn(fn ->
        case :gen_tcp.accept(listener) do
          {:ok, socket} ->
            receive do
              :never -> :gen_tcp.close(socket)
            end

          _error ->
            :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(accepter), do: Process.exit(accepter, :kill)
      :gen_tcp.close(listener)
    end)

    "http://127.0.0.1:#{port}/hanging"
  end

  defp hanging_request(url) do
    Transport.default_request_fun(%{
      method: :get,
      url: url,
      token: "test-token",
      timeout_ms: 30_000
    })
  end

  defp http_client_frames(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stack} -> Enum.filter(stack, fn {module, _f, _a, _loc} -> http_client_module?(module) end)
      _dead -> []
    end
  end

  defp http_client_module?(module) when module in [:ssl, :ssl_gen_statem, :gen_tcp, :prim_inet, :inet_tcp], do: true

  defp http_client_module?(module) do
    module |> Atom.to_string() |> String.starts_with?(["Elixir.Mint", "Elixir.Finch", "Elixir.Req"])
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)

  defp mailbox_depth(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, depth} -> depth
      _dead -> 0
    end
  end

  defp assert_blocked(pid) do
    refute answers?(pid), "the orchestrator answered; the test is no longer exercising a blocked orchestrator"
  end

  defp refute_eventually_answers(pid), do: wait_until(fn -> not answers?(pid) end)

  defp answers?(pid) do
    GenServer.call(pid, :poll_status, 100)
    true
  catch
    :exit, _reason -> false
  end

  defp wait_until_waiting(pid) do
    wait_until(fn -> Process.info(pid, :status) == {:status, :waiting} end)
  end

  defp wait_until(predicate, attempts \\ 100) do
    cond do
      predicate.() -> :ok
      attempts <= 0 -> flunk("condition never held")
      true -> Process.sleep(50) && wait_until(predicate, attempts - 1)
    end
  end
end
