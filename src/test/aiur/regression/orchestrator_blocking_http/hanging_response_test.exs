defmodule Aiur.Regression.OrchestratorBlockingHttp.HangingResponseTest do
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

  import Aiur.OrchestratorBlockingHttpSupport

  alias Aiur.GitHub.{Budget, Transport}

  @cli_budget_ms 5_000
  @locked_release_deadline_ms 1_500

  setup do
    setup_orchestrator()
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

      assert_receive {:request_finished, {:error, {:aiur, :unknown, :fetch_deadline_exceeded}}}, 2_000
    end

    test "a pre-ready deadline reaps the request guardian and its waiting worker" do
      Application.put_env(:aiur, :github_request_deadline_ms, 300)

      {caller, guardian, worker} = block_request_guardian_at(:before_ready)

      assert_receive {:request_finished, ^caller, {:error, {:aiur, :unknown, :fetch_deadline_exceeded}}}, 2_000
      wait_until(fn -> not Process.alive?(guardian) end)
      wait_until(fn -> not Process.alive?(worker) end)
    end

    test "a pre-ack deadline reaps the request guardian and its waiting worker" do
      Application.put_env(:aiur, :github_request_deadline_ms, 300)

      {caller, guardian, worker} = block_request_guardian_at(:before_ack)

      assert_receive {:request_finished, ^caller, {:error, {:aiur, :unknown, :fetch_deadline_exceeded}}}, 2_000
      wait_until(fn -> not Process.alive?(guardian) end)
      wait_until(fn -> not Process.alive?(worker) end)
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

  test "a locked shared budget cannot strand the orchestrator", %{orchestrator: pid} do
    budget_dir = Aiur.TestSupport.tmp_root!("aiur-orchestrator-budget")
    previous_enabled = Application.get_env(:aiur, :github_budget_enabled?)
    previous_dir = Application.get_env(:aiur, :github_budget_dir)

    Application.put_env(:aiur, :github_budget_enabled?, true)
    Application.put_env(:aiur, :github_budget_dir, budget_dir)
    Application.put_env(:aiur, :github_request_deadline_ms, 300)

    on_exit(fn ->
      restore_application_env(:github_budget_enabled?, previous_enabled)
      restore_application_env(:github_budget_dir, previous_dir)
      Aiur.TestCleanup.rm_rf!(budget_dir)
    end)

    assert %{inflight: %{}} = Budget.snapshot("locked-orchestrator-token")
    lock = lock_budget_database(Budget.database_path())
    test_pid = self()

    probe =
      spawn(fn ->
        result =
          eval_on_orchestrator(pid, fn ->
            Transport.default_request_fun(%{
              method: :get,
              url: "https://api.github.com/rate_limit",
              token: "locked-orchestrator-token"
            })
          end)

        send(test_pid, {:locked_budget_result, result})
      end)

    on_exit(fn -> if Process.alive?(probe), do: Process.exit(probe, :kill) end)

    assert_receive {:locked_budget_result, {:error, :github_budget_broker_timeout}}, 2_000
    wait_until(fn -> answers?(pid) end)
    close_port(lock)
  end

  test "a locked lease release is abandoned at its deadline instead of parking on the broker lock", %{
    orchestrator: shared_orchestrator
  } do
    # This request needs an Orchestrator process to reproduce the caller shape,
    # but it must not inherit timers or mailbox work retained by the shared
    # application singleton. Keeping the producer private makes the final
    # response probe causal to this fixture.
    pid = start_supervised!({Orchestrator, initial_poll?: false})

    refute pid == shared_orchestrator

    budget_dir = Aiur.TestSupport.tmp_root!("aiur-orchestrator-release")
    previous_enabled = Application.get_env(:aiur, :github_budget_enabled?)
    previous_dir = Application.get_env(:aiur, :github_budget_dir)

    Application.put_env(:aiur, :github_budget_enabled?, true)
    Application.put_env(:aiur, :github_budget_dir, budget_dir)
    Application.put_env(:aiur, :github_request_deadline_ms, @locked_release_deadline_ms)

    on_exit(fn ->
      restore_application_env(:github_budget_enabled?, previous_enabled)
      restore_application_env(:github_budget_dir, previous_dir)
      Aiur.TestCleanup.rm_rf!(budget_dir)
    end)

    # Subscribe before the request exists, so the release signal cannot be
    # emitted into a subscription that is not yet registered.
    :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, Budget.release_topic())
    on_exit(fn -> Phoenix.PubSub.unsubscribe(Aiur.PubSub, Budget.release_topic()) end)
    release_token_key = Budget.token_key("locked-release-token")

    # `snapshot/1` degrades an unavailable broker to an empty map, so it cannot
    # establish that this fixture can admit the request it is about to test.
    # Acquire and release a separate governed lease first; if startup fails,
    # preserve the broker's status/output log rather than mislabeling it as a
    # release or responsiveness failure.
    assert_budget_admission_ready()

    test_pid = self()
    {url, server} = controlled_json_endpoint(test_pid)

    probe =
      spawn(fn ->
        result =
          eval_on_orchestrator(pid, fn ->
            Transport.default_request_fun(%{
              method: :get,
              url: url,
              token: "locked-release-token"
            })
          end)

        send(test_pid, {:locked_release_result, result})
      end)

    on_exit(fn -> if Process.alive?(probe), do: Process.exit(probe, :kill) end)

    # The request is admitted and in flight before the broker database is
    # locked, so the lock can only be met by the release that closes it.
    assert_receive :release_request_started, 2 * @locked_release_deadline_ms
    lock = lock_budget_database(Budget.database_path())
    send(server, :finish_release_request)

    # The guarantee is a *budget and an outcome*, not a duration.
    #
    # `budget_ms` is how long the release was willing to wait, decided by the
    # request's own deadline before the release runs. It is a property of the
    # code, so machine load cannot move it. The regression this test guards —
    # a release that ignores the request deadline and parks on the broker's
    # SQLite `busy_timeout` — grants itself a budget larger than the request
    # deadline, and that shows up here directly.
    #
    # `outcome` then confirms the budget was actually honoured: against a
    # database held under `BEGIN EXCLUSIVE`, a release that stops at its
    # deadline reports `:deadline_exceeded`, while one that waits out the lock
    # is eventually acknowledged and reports `:released`.
    #
    # The old assertion, `elapsed_ms < 2 * @locked_release_deadline_ms`, timed
    # a window that also contained unbounded admission work — an Orchestrator
    # `GenServer.call`, a `python3` broker spawn and the SQLite open — against
    # a ceiling derived only from the post-admission deadline. It therefore
    # asserted that *setup* finished in under @locked_release_deadline_ms,
    # which is a claim about the machine rather than about the release.
    #
    # The receive bounds below are lost-signal safety nets only. Both are far
    # larger than any legitimate outcome, and neither is what separates pass
    # from fail.
    assert_receive {:github_budget_lease_released, %{token_key: ^release_token_key} = release}, 15_000

    assert release.budget_ms <= @locked_release_deadline_ms
    assert release.outcome == :deadline_exceeded

    # The release outcome is only evidence about an attempt. The lock owner
    # confirms it still owns the exclusive transaction *after* the release
    # completed, so the result below cannot be attributed to the fixture's
    # 30-second fallback expiry or a released lock.
    assert_lock_held(lock)

    # Ordering, not timing: the release above is charged inside the request, so
    # the caller's response arriving after it is the non-blocking property —
    # the abandoned release did not swallow the result — and the Orchestrator
    # is still answering once both have landed.
    assert_receive {:locked_release_result, {:ok, %{status: 200}}}, 15_000
    assert_orchestrator_answers(pid)
    close_port(lock)
  end
end
