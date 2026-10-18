defmodule Aiur.OrchestratorBlockingHttpSupport do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks
  import ExUnit.CaptureLog

  alias Aiur.GitHub.{Budget, Transport}
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{CommentPolling, SnapshotStore, StatusReport}

  @locked_release_deadline_ms 1_500

  def setup_orchestrator do
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

      restore_orchestrator(pid, original_state)
    end)

    {:ok, orchestrator: pid}
  end

  defp restore_orchestrator(pid, original_state) do
    if Process.alive?(pid) do
      :sys.replace_state(pid, fn _state -> original_state end)
    end
  end

  # The tracker gate is what this file cannot arrange from the shared workflow
  # file, so it is stated here; the property under test is the fan-out, not the
  # gate in front of it.
  def comment_poll_opts(review_issue_fetcher) do
    [tracker_kind: "github", repo: "owner/repo", token: "test-gh-token", review_issue_fetcher: review_issue_fetcher]
  end

  def start_blocked_comment_poll(orchestrator) do
    test_pid = self()

    request_fun = fn _request ->
      target = self()

      Transport.off_process_request(%{}, fn ->
        send(test_pid, {:owned_comment_request_started, target, self()})
        Process.sleep(:infinity)
      end)
    end

    opts =
      comment_poll_opts(fn _states -> {:ok, []} end)
      |> Keyword.put(:request_fun, request_fun)

    :sys.replace_state(orchestrator, fn state ->
      state
      |> Map.put(:running, %{"57" => %{identifier: "57"}})
      |> CommentPolling.start_async(opts)
    end)

    assert_receive {:owned_comment_request_started, target, request}, 5_000
    wait_until(fn -> is_pid(:sys.get_state(orchestrator).github_comment_poll.pid) end)
    poll = :sys.get_state(orchestrator).github_comment_poll.pid
    {poll, target, request}
  end

  def await_async_started(%Aiur.Orchestrator.State{github_comment_poll: %{ref: ref, owner: owner}} = state) do
    receive do
      {:github_comment_poll_started, ^ref, ^owner, pid} ->
        CommentPolling.apply_async_started(state, ref, owner, pid)
    after
      5_000 -> flunk("the asynchronous comment poll never announced its pid")
    end
  end

  def assert_owner_death_reaps_poll(orchestrator, blocked_phase) do
    test_pid = self()

    phase_hook = fn phase, owner, poll ->
      if phase == blocked_phase do
        send(test_pid, {:owner_phase_reached, phase, owner, poll})
        Process.sleep(:infinity)
      end
    end

    review_issue_fetcher = fn _states ->
      send(test_pid, {:owned_poll_work_started, self()})
      Process.sleep(:infinity)
    end

    opts = Keyword.put(comment_poll_opts(review_issue_fetcher), :owner_phase_hook, phase_hook)

    :sys.replace_state(orchestrator, fn state -> CommentPolling.start_async(state, opts) end)

    assert_receive {:owner_phase_reached, ^blocked_phase, owner, poll}, 5_000

    on_exit(fn ->
      if Process.alive?(owner), do: Process.exit(owner, :kill)
      if Process.alive?(poll), do: Process.exit(poll, :kill)
    end)

    work_process =
      if blocked_phase == :after_start_before_guard do
        assert_receive {:owned_poll_work_started, worker}, 5_000
        worker
      else
        refute_receive {:owned_poll_work_started, _worker}, 100
        nil
      end

    owner_ref = Process.monitor(owner)
    poll_ref = Process.monitor(poll)
    work_ref = if is_pid(work_process), do: Process.monitor(work_process)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
    assert_receive {:DOWN, ^poll_ref, :process, ^poll, :killed}, 5_000

    if is_reference(work_ref) do
      assert_receive {:DOWN, ^work_ref, :process, ^work_process, _reason}, 5_000
    end

    wait_until(fn -> :sys.get_state(orchestrator).github_comment_poll == nil end)

    refute Process.alive?(poll)
  end

  # `:sys.replace_state/2` evaluates its function inside the target process, so
  # this answers "what does this code see when it runs on the Orchestrator?".
  def eval_on_orchestrator(pid, fun) do
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

  def assert_same_poll_at_elapsed(orchestrator, opts, poll, elapsed_ms) do
    :sys.replace_state(orchestrator, fn state ->
      state = put_in(state.github_comment_poll.started_at_ms, System.monotonic_time(:millisecond) - elapsed_ms)
      CommentPolling.start_async(state, opts)
    end)

    current_poll = :sys.get_state(orchestrator).github_comment_poll
    assert current_poll.ref == poll.ref
    assert current_poll.owner == poll.owner
    assert current_poll.pid == poll.pid
  end

  # The read model retains the projection its rows are built from, so a test
  # publishing a view has to hand over both.
  def publish_current_view(pid) do
    state = :sys.get_state(pid)
    SnapshotStore.publish(Orchestrator, StatusReport.snapshot_payload(state), state)
  end

  # A parked duration-capped agent: enough shape for the read model to render a
  # paused row that `resume` can select by issue id/identifier.
  def paused_duration_entry(issue_id, identifier) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{
        id: issue_id,
        identifier: identifier,
        state: "in-progress",
        title: "Duration paused #{identifier}"
      },
      control: %{
        status: :paused,
        generation: 1,
        version: 1,
        application_confirmation: :confirmed,
        can_interrupt: true,
        safe_checkpoints: []
      },
      paused_reason: :max_agent_duration,
      session_id: "thread-#{identifier}",
      started_at: DateTime.utc_now()
    }
  end

  # A listener that completes the TCP handshake and then never answers — the
  # slow-peer shape that leaves a client parked in `recv`.
  def hanging_endpoint do
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

  def controlled_json_endpoint(test_pid) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
        send(test_pid, :release_request_started)

        receive do
          :finish_release_request ->
            :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 11\r\n\r\n{\"ok\":true}")
            :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    {"http://127.0.0.1:#{port}/repos/owner/repo/issues/1477", server}
  end

  def lock_budget_database(path) do
    python = System.find_executable("python3") || flunk("python3 is required")

    script =
      "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('BEGIN EXCLUSIVE'); print('locked', flush=True); " <>
        "\nfor command in sys.stdin:\n if command == 'assert-held\\n': print('held', flush=True)\n elif command == 'release\\n': c.rollback(); print('released', flush=True); break"

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(python)},
        [:binary, :exit_status, :stderr_to_stdout, args: [~c"-c", String.to_charlist(script), String.to_charlist(path)]]
      )

    on_exit(fn -> close_port(port) end)
    assert_receive {^port, {:data, "locked\n"}}, 2_000
    port
  end

  def assert_lock_held(port) do
    assert Port.command(port, "assert-held\n")
    assert_receive {^port, {:data, "held\n"}}, 2_000
  end

  def assert_budget_admission_ready do
    request = %{method: :get, url: "https://api.github.com/rate_limit", token: "locked-release-prewarm-token"}

    log = capture_log(fn -> send(self(), {:budget_admission_ready, Budget.acquire(request, timeout_ms: @locked_release_deadline_ms)}) end)
    assert_receive {:budget_admission_ready, result}, 1000

    assert match?({:ok, _lease}, result), "budget broker did not admit the fixture request: #{inspect(result)}; #{log}"
    {:ok, lease} = result

    # Releasing this setup lease is best effort; admission above, not a
    # release acknowledgement, establishes that the broker is ready.
    Budget.release(lease, timeout_ms: @locked_release_deadline_ms)
  end

  def close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  def hanging_request(url) do
    Transport.default_request_fun(%{
      method: :get,
      url: url,
      token: "test-token",
      timeout_ms: 30_000
    })
  end

  def block_request_guardian_at(blocked_phase) when blocked_phase in [:before_ready, :before_ack] do
    test_pid = self()

    phase_hook = fn phase, guardian, worker ->
      if phase == blocked_phase do
        send(test_pid, {:request_guardian_phase, phase, guardian, worker})
        Process.sleep(:infinity)
      end
    end

    caller =
      spawn(fn ->
        result =
          Transport.off_process_request(
            %{guardian_phase_hook: phase_hook},
            fn -> Process.sleep(:infinity) end
          )

        send(test_pid, {:request_finished, self(), result})
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

    {guardian, worker} =
      receive do
        {:request_guardian_phase, ^blocked_phase, guardian, worker} ->
          {guardian, worker}
      after
        2_000 -> flunk("request guardian did not reach #{blocked_phase}")
      end

    on_exit(fn ->
      if Process.alive?(guardian), do: Process.exit(guardian, :kill)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    {caller, guardian, worker}
  end

  def http_client_frames(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stack} -> Enum.filter(stack, fn {module, _f, _a, _loc} -> http_client_module?(module) end)
      _dead -> []
    end
  end

  defp http_client_module?(module) when module in [:ssl, :ssl_gen_statem, :gen_tcp, :prim_inet, :inet_tcp], do: true

  defp http_client_module?(module) do
    module |> Atom.to_string() |> String.starts_with?(["Elixir.Mint", "Elixir.Finch", "Elixir.Req"])
  end

  def restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  def restore_application_env(key, value), do: Application.put_env(:aiur, key, value)

  # Counts `send` trace messages received by this process that were sent *by
  # this process* to `pid`. `:erlang.trace(pid, true, [:send])` reports every
  # send to `pid` as `{:trace, sender, :send, msg, pid}`, so filtering on the
  # sender isolates the traffic this test's own code generates — concurrent
  # async tests messaging the shared Orchestrator are ambient noise and cannot
  # fail this assertion.
  def sends_from_self(pid, me) do
    flush_trace(pid, me, 0)
  end

  defp flush_trace(pid, me, count) do
    receive do
      {:trace, ^me, :send, _message, ^pid} -> flush_trace(pid, me, count + 1)
      _other_trace -> flush_trace(pid, me, count)
    after
      10 -> count
    end
  end

  def assert_blocked(pid) do
    refute answers?(pid), "the orchestrator answered; the test is no longer exercising a blocked orchestrator"
  end

  def refute_eventually_answers(pid), do: wait_until(fn -> not answers?(pid) end)

  def answers?(pid) do
    GenServer.call(pid, :poll_status, 100)
    true
  catch
    :exit, _reason -> false
  end

  def assert_orchestrator_answers(pid) do
    result =
      try do
        {:ok, GenServer.call(pid, :poll_status, 100)}
      catch
        :exit, reason -> {:exit, reason}
      end

    case result do
      {:ok, _status} -> :ok
      {:exit, reason} -> flunk("orchestrator poll_status exited: #{inspect(reason)}; #{inspect(orchestrator_probe_context(pid))}")
    end
  end

  defp orchestrator_probe_context(pid) do
    %{
      alive?: Process.alive?(pid),
      mailbox: Process.info(pid, :message_queue_len),
      stacktrace: Process.info(pid, :current_stacktrace),
      status: Process.info(pid, :status)
    }
  end

  def wait_until_waiting(pid) do
    wait_until(fn -> Process.info(pid, :status) == {:status, :waiting} end)
  end

  def wait_until(predicate, attempts \\ 100) do
    cond do
      predicate.() -> :ok
      attempts <= 0 -> flunk("condition never held")
      true -> Process.sleep(50) && wait_until(predicate, attempts - 1)
    end
  end
end
