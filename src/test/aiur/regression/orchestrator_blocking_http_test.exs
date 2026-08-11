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
      :ok = SnapshotStore.publish(Orchestrator, pid |> :sys.get_state() |> StatusReport.snapshot_payload())
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

    test "the orchestrator mailbox does not grow while the fetch is outstanding", %{orchestrator: pid} do
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
      assert http_client_frames(pid) == [],
             "the orchestrator is holding the socket: #{inspect(Process.info(pid, :current_stacktrace))}"
    end
  end

  test "a fleet view behind its producer is rendered with its age, not as current", %{orchestrator: pid} do
    previous_ceiling = Application.get_env(:aiur, :snapshot_stale_age_ceiling_ms)
    Application.put_env(:aiur, :snapshot_stale_age_ceiling_ms, 50)
    on_exit(fn -> restore_application_env(:snapshot_stale_age_ceiling_ms, previous_ceiling) end)

    :ok = SnapshotStore.publish(Orchestrator, pid |> :sys.get_state() |> StatusReport.snapshot_payload())
    on_exit(fn -> SnapshotStore.forget(Orchestrator) end)
    Process.sleep(120)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "STALE FLEET VIEW — showing the last-known-good snapshot,"
    assert output =~ "old (the orchestrator has stopped publishing)"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
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
