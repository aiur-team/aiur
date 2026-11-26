defmodule Aiur.GitHub.Transport.OffProcess do
  @moduledoc """
  Bounded HTTP worker lifetimes and response bodies for the GitHub transport.

  The guardian monitors the caller and owns the worker lifetime. Request-start
  handshakes, links and monitors stay together here so deadlines cover startup
  as well as network work.
  """

  alias Aiur.GitHub.Transport

  require Logger

  @doc """
  Runs `request_fun` on a throwaway process so the caller never owns the socket.

  Returns `{:error, {:aiur, :unknown, :fetch_deadline_exceeded}}` when the request does not finish
  inside the deadline; the process is killed, so the socket is released rather
  than leaked. Exceptions and exits raised inside it are re-raised on the caller
  so error handling upstream is unchanged.

  The worker is spawned directly rather than started under a `Task.Supervisor`.
  `Task.Supervisor.async_nolink/2` starts its child through
  `GenServer.call(supervisor, ..., :infinity)`, so every GitHub request in the
  application would queue on one supervisor process — the same one that owns
  long-lived agent tasks and is parked synchronously by
  `Aiur.Orchestrator.AgentTeardown` while a child shuts down. That is an
  unbounded wait in front of the deadline, and a fix for "one process holds a
  socket" must not introduce "every request holds a global lock". `spawn_monitor`
  has no such round trip, so the deadline below covers the whole operation
  including acquiring the worker.
  """
  @spec off_process_request(map(), (-> term())) :: term()
  def off_process_request(request, request_fun) when is_function(request_fun, 0) do
    deadline_ms = Transport.request_deadline_ms(request)
    deadline_at_ms = System.monotonic_time(:millisecond) + deadline_ms

    off_process_request(request, request_fun, deadline_at_ms, deadline_ms)
  end

  @doc false
  @spec off_process_request(map(), (-> term()), integer(), pos_integer()) :: term()
  def off_process_request(request, request_fun, deadline_at_ms, deadline_ms) do
    caller = self()
    callers = [caller | Process.get(:"$callers", [])]
    logger_metadata = Logger.metadata()

    guardian_ready_ref = make_ref()

    {guardian, guardian_ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        caller_ref = Process.monitor(caller)

        # The link is the guardian's inverse lifetime edge. In particular, a
        # deadline may kill the guardian before readiness or start is
        # acknowledged; the request worker must die with it in either window.
        {worker, worker_ref} =
          :erlang.spawn_opt(
            fn ->
              receive do
                :start -> :ok
              end

              # `Req.Test` and friends resolve stubs through `$callers`, and log
              # lines keep the caller's metadata, so both are carried over.
              Process.put(:"$callers", callers)
              Logger.metadata(logger_metadata)

              result =
                try do
                  {:ok, request_fun.()}
                catch
                  kind, reason -> {:raised, kind, reason, __STACKTRACE__}
                end

              send(caller, {Transport, self(), result})
            end,
            [:link, :monitor]
          )

        run_guardian_phase_hook(request, :before_ready, worker)
        send(caller, {guardian_ready_ref, self(), worker})
        await_request_start(caller, caller_ref, guardian_ready_ref, worker, worker_ref, request)
      end)

    with {:ok, worker} <- await_guardian_ready(guardian, guardian_ref, guardian_ready_ref, deadline_at_ms) do
      monitor_ref = Process.monitor(worker)

      case start_guarded_request(guardian, guardian_ref, guardian_ready_ref, deadline_at_ms) do
        :ok ->
          await_off_process_request(request, worker, monitor_ref, deadline_at_ms, deadline_ms)

        error ->
          Process.demonitor(monitor_ref, [:flush])
          error
      end
    end
  end

  defp await_request_start(caller, caller_ref, ready_ref, worker, worker_ref, request) do
    receive do
      {:start_guarded_request, ^ready_ref} ->
        run_guardian_phase_hook(request, :before_ack, worker)
        send(caller, {:guarded_request_started, ready_ref})
        send(worker, :start)
        guard_worker_lifetime(caller, caller_ref, worker, worker_ref)

      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        Process.exit(worker, :kill)
        await_worker_down(worker, worker_ref)
    end
  end

  defp run_guardian_phase_hook(request, phase, worker) do
    case Map.get(request, :guardian_phase_hook) do
      hook when is_function(hook, 3) -> hook.(phase, self(), worker)
      _other -> :ok
    end
  end

  defp await_guardian_ready(guardian, guardian_ref, ready_ref, deadline_at_ms) do
    receive do
      {^ready_ref, ^guardian, worker} -> {:ok, worker}
      {:DOWN, ^guardian_ref, :process, ^guardian, reason} -> {:error, {:github_request_guardian_exit, reason}}
    after
      remaining_deadline_ms(deadline_at_ms) ->
        stop_request_guardian(guardian, guardian_ref)
        {:error, {:aiur, :unknown, :fetch_deadline_exceeded}}
    end
  end

  defp start_guarded_request(guardian, guardian_ref, ready_ref, deadline_at_ms) do
    with :ok <- link_request_guardian(guardian) do
      send(guardian, {:start_guarded_request, ready_ref})

      receive do
        {:guarded_request_started, ^ready_ref} ->
          Process.demonitor(guardian_ref, [:flush])
          :ok

        {:DOWN, ^guardian_ref, :process, ^guardian, reason} ->
          {:error, {:github_request_guardian_exit, reason}}
      after
        remaining_deadline_ms(deadline_at_ms) ->
          Process.unlink(guardian)
          stop_request_guardian(guardian, guardian_ref)
          {:error, {:aiur, :unknown, :fetch_deadline_exceeded}}
      end
    end
  end

  defp link_request_guardian(guardian) do
    Process.link(guardian)
    :ok
  catch
    :exit, :noproc -> {:error, {:github_request_guardian_exit, :noproc}}
    :error, :badarg -> {:error, {:github_request_guardian_exit, :noproc}}
  end

  # The request worker is deliberately unlinked from its caller so an
  # unexpected worker exit cannot take a GenServer down. This responsive
  # guardian supplies the inverse lifetime edge: when a poll target/caller is
  # cancelled, it kills the possibly-blocked socket worker before exiting.
  defp guard_worker_lifetime(caller, caller_ref, worker, worker_ref) do
    receive do
      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
        end

      {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
        Process.demonitor(caller_ref, [:flush])
        Process.unlink(caller)
    end
  end

  defp await_off_process_request(request, worker, monitor_ref, deadline_at_ms, deadline_ms) do
    receive do
      {Transport, ^worker, {:ok, result}} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {Transport, ^worker, {:raised, kind, reason, stacktrace}} ->
        Process.demonitor(monitor_ref, [:flush])
        :erlang.raise(kind, reason, stacktrace)

      {:DOWN, ^monitor_ref, :process, ^worker, reason} ->
        # The worker died without reporting. It never owned this caller's
        # mailbox, so surface it as an error rather than taking the caller down.
        {:error, {:github_request_task_exit, reason}}
    after
      remaining_deadline_ms(deadline_at_ms) ->
        abandon_off_process_request(request, worker, monitor_ref, deadline_ms)
    end
  end

  defp remaining_deadline_ms(deadline_at_ms),
    do: max(deadline_at_ms - System.monotonic_time(:millisecond), 0)

  defp stop_request_guardian(guardian, guardian_ref) do
    Process.exit(guardian, :kill)

    receive do
      {:DOWN, ^guardian_ref, :process, ^guardian, _reason} -> :ok
    end
  end

  defp await_worker_down(worker, worker_ref) do
    receive do
      {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
    end
  end

  defp abandon_off_process_request(request, worker, monitor_ref, deadline_ms) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, ^worker, _reason} -> :ok
    end

    # The worker may have answered in the gap between the deadline firing and
    # the kill landing; drop that reply so it cannot be read as the result of
    # some later request on this process.
    receive do
      {Transport, ^worker, _late_result} -> :ok
    after
      0 -> :ok
    end

    Logger.warning(
      "GitHub request exceeded its #{deadline_ms}ms process deadline and was abandoned: " <>
        "#{inspect(Map.get(request, :method))} #{inspect(Map.get(request, :url))}"
    )

    {:error, {:aiur, :unknown, :fetch_deadline_exceeded}}
  end

  @doc false
  @spec maybe_bound_response(keyword(), map()) :: keyword()
  def maybe_bound_response(options, %{max_response_bytes: limit})
      when is_integer(limit) and limit > 0 do
    Keyword.put(options, :into, bounded_response_collector(limit))
  end

  def maybe_bound_response(options, _req), do: options

  defp bounded_response_collector(limit) do
    fn {:data, data}, {request, response} ->
      body = [response.body, data] |> IO.iodata_to_binary()

      if byte_size(body) <= limit do
        {:cont, {request, %{response | body: body}}}
      else
        response =
          response
          |> Map.put(:body, "")
          |> Req.Response.put_private(:aiur_response_too_large, true)

        {:halt, {request, response}}
      end
    end
  end
end
