defmodule Aiur.TestSupport.Processes do
  alias Aiur.TestSupport.EndpointStubs
  alias Aiur.TestSupport.RuntimeChildren

  @doc "Waits for tracked task completions until the orchestrator satisfies a state predicate."
  @spec await_orchestrator_state(pid(), (map() -> boolean())) :: map()
  def await_orchestrator_state(pid, predicate) do
    :ok = Aiur.AgentPubSub.subscribe_running()
    :ok = Aiur.AgentPubSub.subscribe_poll_state()
    await_orchestrator_state(pid, predicate, System.monotonic_time(:millisecond) + 15_000)
  end

  defp await_orchestrator_state(pid, predicate, deadline) do
    state = :sys.get_state(pid)

    if predicate.(state) do
      state
    else
      refs = Map.new(state.tracker_tasks, fn {_ref, job} -> {Process.monitor(job.task.pid), true} end)
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      try do
        receive do
          {:DOWN, ref, :process, _task, _reason} when is_map_key(refs, ref) -> :ok
          {:running_changed, _summaries} when map_size(refs) == 0 -> :ok
          {:poll_state_changed, _poll} when map_size(refs) == 0 -> :ok
        after
          remaining -> raise("Timed out waiting for orchestrator tracker result; tracker tasks held: #{inspect(Enum.map(state.tracker_tasks, fn {_ref, job} -> job.key end))}")
        end
      after
        Enum.each(refs, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)
      end

      await_orchestrator_state(pid, predicate, deadline)
    end
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  @doc """
  Returns a skip reason when `pgrep -P <pid>` cannot read the OS process list,
  or `nil` when it can.

  The process-reaping tests spawn a `bash -lc` wrapper, discover the child it
  forks via `pgrep -P`, then assert the production reap path kills the whole
  tree. Both the discovery and the production reap (`RemoteControl.collect_descendants/1`)
  depend on `pgrep`. In sandboxes where `pgrep` cannot reach the process list —
  e.g. the macOS agent sandbox, which fails with `sysmond service not found` /
  `pgrep: Cannot get process list` — those tests strand at child discovery
  before the code under test even runs. Tests gate on this with
  `@tag skip: @pgrep_skip_reason` so they skip with a clear reason there and
  still run wherever `pgrep` works (Linux CI, the dogfood box, macOS dev).

  The probe is functional, not OS-based: it backgrounds a known child and
  confirms `pgrep -P` actually discovers it (exit 0). A broken `pgrep` errors
  instead of returning the child, which is exactly the failure being guarded.
  """
  @spec pgrep_skip_reason() :: String.t() | nil
  def pgrep_skip_reason do
    if System.find_executable("pgrep") do
      probe =
        ~s(sleep 1 & child=$!; pgrep -P $$ >/dev/null 2>&1; rc=$?; kill "$child" 2>/dev/null; exit $rc)

      case System.cmd("sh", ["-c", probe], stderr_to_stdout: true) do
        {_out, 0} ->
          nil

        _ ->
          "pgrep cannot read the process list in this environment (e.g. macOS sandbox: sysmond unavailable)"
      end
    else
      "pgrep is not on $PATH"
    end
  end

  def stop_default_http_server do
    case Process.whereis(Aiur.Supervisor) do
      supervisor when is_pid(supervisor) ->
        stop_default_http_server(supervisor)

      nil ->
        RuntimeChildren.ensure_aiur_supervisor_running()
    end
  end

  defp stop_default_http_server(supervisor) do
    case stop_default_http_server_child() do
      :ok -> :ok
      :supervisor_unavailable -> RuntimeChildren.recover_stopped_supervisor(supervisor, &RuntimeChildren.ensure_aiur_supervisor_running/0)
    end
  end

  defp stop_default_http_server_child do
    case Enum.find(Supervisor.which_children(Aiur.Supervisor), fn
           {Aiur.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {Aiur.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  catch
    :exit, _reason -> :supervisor_unavailable
  end

  @doc """
  Stops a server during test teardown, tolerating a process that has already
  exited.

  `start_link`ed servers are linked to the test process, so when the test
  finishes its exit propagates over the link and tears the server down. An
  `on_exit/1` callback runs *afterward* in a separate process, so a
  `Process.alive?/1` / `Process.whereis/1` guard around `GenServer.stop/1` is a
  TOCTOU race: the guard observes the server alive, the link teardown then kills
  it, and the stop crashes with `no process`. Under coverage instrumentation the
  teardown window widens and the race trips intermittently. `safe_stop/1`
  catches that `:exit` instead of guarding, so an already-dead process is a
  no-op. Accepts a pid or a registered name.
  """
  @spec safe_stop(GenServer.server()) :: :ok
  def safe_stop(server) do
    GenServer.stop(server)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Returns an `AiurWeb.Endpoint` pid that is guaranteed to outlive this test.

  `AiurWeb.Endpoint` is a singleton registered under its own module name, and
  who owns it is not fixed. Whether `Aiur.Supervisor` starts one depends on the
  ambient dashboard configuration the application read at boot: CI has none and
  gets no endpoint, a developer box with `~/.aiur/config` gets a permanent one.
  Tests that need an endpoint therefore start their own under the ExUnit test
  supervisor, which tears it down when the test ends — and for a short window
  after that the *name* is still registered while the process finishes
  terminating.

  Three patterns built on that landscape are wrong, and #2288 is what each one
  looks like when it fails:

    * `if is_nil(Process.whereis(AiurWeb.Endpoint)), do: start_supervised!(...)`
      reads "registered right now" as "will be alive for this whole test". Against
      a *dying* endpoint it declines to start its own and then loses the config
      ETS table mid-test — `Endpoint.call/2` raises `ArgumentError` with "the
      table identifier does not refer to an existing ETS table".

    * a bare `start_supervised!({AiurWeb.Endpoint, []})` raises on the
      `{:error, {:already_started, pid}}` that same window produces.

    * waiting unconditionally for the already-started pid's `:DOWN` hangs
      forever against a permanent `Aiur.Supervisor` child, which is not dying
      and never will.

  The first two are functions of which test ran immediately before, so they
  appear and vanish with the seed and with partition membership; the third is a
  function of the machine. This helper keys on provenance instead, which is
  knowable without waiting to see what happens:

    * an application-owned endpoint is reused, because in the ordinary case the
      supervisor holding it is not stopped by a test and restarts it if one
      tries;

    * anything else registered under that name belongs to a finished test's
      supervisor and is mid-teardown, so its `:DOWN` is guaranteed to arrive and
      is waited for, without a grace period, before starting our own.

  No wall-clock window is involved either way, so the result cannot change with
  machine load. Call it once per test.

  The provenance test is about where a process was started, not whether it is
  healthy now, and those come apart in one case: some tests deliberately stop
  `Aiur.Supervisor` (which is why `ensure_aiur_supervisor_running/0` exists). An
  application endpoint caught mid-teardown still carries `Aiur.Supervisor` in
  its `$ancestors` and would be reused here, which is the #2288 shape again. No
  current caller runs in that window; a test that stops the supervisor and then
  wants an endpoint must restore it first rather than rely on this function.
  """
  @spec start_owned_endpoint!() :: pid()
  def start_owned_endpoint! do
    refuse_global_endpoint_stubs!()

    case ExUnit.Callbacks.start_supervised({AiurWeb.Endpoint, []}) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        adopt_or_replace_endpoint(pid)

      {:error, reason} ->
        raise "failed to start AiurWeb.Endpoint under the test supervisor: #{inspect(reason)}"
    end
  end

  # Every test that renders a dashboard reads the global env, so a stub there
  # is called by foreign tests (#4908).
  defp refuse_global_endpoint_stubs! do
    case for({key, value} <- Application.get_env(:aiur, AiurWeb.Endpoint, []), EndpointStubs.stub?(value), do: key) do
      [] -> :ok
      keys -> raise "AiurWeb.Endpoint env holds test stubs #{inspect(keys)}; scope them with EndpointStubs.scope/1"
    end
  end

  defp adopt_or_replace_endpoint(pid) do
    cond do
      application_owned?(pid) ->
        pid

      # The wait is bounded only so that a mis-keyed provenance test fails
      # loudly and says which process it misread. A genuinely dying endpoint
      # returns in microseconds, so this bound is never a race window; if it is
      # ever reached, the classification above is wrong and the timeout value is
      # not the thing to change.
      await_process_down(pid, 10_000) == :ok ->
        start_owned_endpoint!()

      true ->
        raise "AiurWeb.Endpoint #{inspect(pid)} was classified as a dying test-owned endpoint " <>
                "but is still alive after 10s; $ancestors=#{inspect(ancestors(pid))}"
    end
  end

  # `$ancestors` is written by `proc_lib` at spawn and never rewritten, so it
  # names the supervision tree the process was actually started under rather
  # than whatever happens to be registered now.
  defp application_owned?(pid), do: Aiur.Supervisor in ancestors(pid)

  defp ancestors(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, :"$ancestors", [])
      nil -> []
    end
  end

  defdelegate await_process_down(process, timeout \\ 2_000), to: RuntimeChildren

  @doc """
  Waits until `Aiur.Supervisor` has replaced the child registered as `name`
  after `prior` exited, and has restarted every child after it.

  The tree is `:rest_for_one`, so one child's exit restarts every later child
  too. The replacement registers its name while that cascade is still running.
  A test that returns at that point leaves the later children (for example
  `Aiur.Opencode.ActiveTurns`) down for the next test in the partition.

  The steps are signal-based, never a duration:

    1. monitor `prior` and wait for its `:DOWN`;
    2. call the supervisor. It restarts the whole cascade inside one callback,
       so the call returns only after any restart in progress is complete;
    3. read the registered name. If the supervisor has not yet processed the
       exit, wait briefly with a bounded `receive` and repeat step 2.

  The whole wait is bounded by `timeout` (default 5s). The bound only decides
  how long a real failure takes to report. A failure names the step:
  `{:error, {:prior_not_down, name}}`, `{:error, {:supervisor_unresponsive,
  Aiur.Supervisor}}` or `{:error, {:not_restarted, name}}`.
  """
  @spec await_supervised_restart(atom(), pid(), non_neg_integer()) ::
          {:ok, pid()}
          | {:error, {:prior_not_down, atom()} | {:supervisor_unresponsive, atom()} | {:not_restarted, atom()}}
  def await_supervised_restart(name, prior, timeout \\ 5_000)
      when is_atom(name) and is_pid(prior) and is_integer(timeout) and timeout >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout

    case await_process_down(prior, remaining_ms(deadline)) do
      :ok -> await_registered_replacement(name, prior, deadline)
      :error -> {:error, {:prior_not_down, name}}
    end
  end

  defp await_registered_replacement(name, prior, deadline) do
    # A floor on the call bound: at the deadline, a live supervisor must still
    # answer, so the failure reads as `:not_restarted`, not as unresponsive.
    with :ok <- await_supervisor_idle(Aiur.Supervisor, max(remaining_ms(deadline), 100)) do
      case Process.whereis(name) do
        pid when is_pid(pid) and pid != prior -> {:ok, pid}
        _not_replaced -> recheck_registered_replacement(name, prior, deadline)
      end
    end
  end

  defp recheck_registered_replacement(name, prior, deadline) do
    case remaining_ms(deadline) do
      0 ->
        {:error, {:not_restarted, name}}

      remaining ->
        # The exit signal can reach the supervisor after our call. Give it a
        # moment, then call again: the call is the real barrier.
        receive do
        after
          min(remaining, 10) -> :ok
        end

        await_registered_replacement(name, prior, deadline)
    end
  end

  defp await_supervisor_idle(supervisor, timeout) do
    if RuntimeChildren.supervisor_accepting_calls?(Process.whereis(supervisor), timeout),
      do: :ok,
      else: {:error, {:supervisor_unresponsive, supervisor}}
  end

  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
