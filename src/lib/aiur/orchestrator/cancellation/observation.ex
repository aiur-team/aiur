defmodule Aiur.Orchestrator.Cancellation.Observation do
  @moduledoc false

  alias Aiur.Orchestrator.AgentTeardown
  alias Aiur.ProcessTree

  @contract "aiur.ticket_cancel"
  @contract_version 1
  @tracker_state "cancelled"
  @default_exit_timeout_ms 1_000
  @default_os_exit_timeout_ms 4_250
  @os_exit_poll_ms 25

  @type process_status :: :exited | :still_running | :kill_failed | :generation_changed
  @type result :: %{
          contract: String.t(),
          contract_version: pos_integer(),
          issue_identifier: String.t(),
          tracker_state: String.t(),
          process: %{
            handle: String.t(),
            status: String.t(),
            exit_status: String.t() | nil,
            exited_at: String.t() | nil,
            observed_at: String.t()
          }
        }

  @spec observe_exit(reference(), pid(), map(), String.t(), term(), keyword()) :: result()
  def observe_exit(monitor, pid, %{handle: handle} = stage, identifier, stop_result, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_exit_timeout_ms)

    receive do
      {:DOWN, ^monitor, :process, ^pid, reason} ->
        observe_shell_exit(stage, identifier, handle, reason, stop_result, opts)
    after
      timeout_ms ->
        Process.demonitor(monitor, [:flush])
        status = if stop_result == :ok, do: :still_running, else: :kill_failed
        result(identifier, handle, status, nil, now(opts))
    end
  end

  @spec result(String.t(), String.t(), process_status(), term(), DateTime.t()) :: result()
  def result(identifier, handle, status, exit_reason, %DateTime{} = observed_at)
      when is_binary(identifier) and is_binary(handle) and
             status in [:exited, :still_running, :kill_failed, :generation_changed] do
    observed_at = DateTime.to_iso8601(observed_at)
    exited? = status == :exited

    %{
      contract: @contract,
      contract_version: @contract_version,
      issue_identifier: identifier,
      tracker_state: @tracker_state,
      process: %{
        handle: handle,
        status: Atom.to_string(status),
        exit_status: if(exited?, do: exit_status(exit_reason), else: nil),
        exited_at: if(exited?, do: observed_at, else: nil),
        observed_at: observed_at
      }
    }
  end

  @doc false
  @spec request_stop((pid() -> term()), pid()) :: term()
  def request_stop(stop_fun, pid) do
    stop_fun.(pid)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp observe_shell_exit(stage, identifier, handle, exit_reason, stop_result, opts) do
    reap_fun = Keyword.get(opts, :reap_fun, &AgentTeardown.schedule_cancelled_shell_cleanup/1)
    shell_alive_fun = Keyword.get(opts, :shell_alive_fun, &shell_alive?/1)
    os_exit_timeout_ms = Keyword.get(opts, :os_exit_timeout_ms, @default_os_exit_timeout_ms)

    status =
      if shell_identity?(stage) do
        _ = request_reap(reap_fun, stage)

        case await_shell_exit(shell_alive_fun, stage, os_exit_timeout_ms) do
          :gone -> :exited
          :alive -> non_exit_status(stop_result)
          :unknown -> :kill_failed
        end
      else
        :kill_failed
      end

    result(identifier, handle, status, exit_reason, now(opts))
  end

  defp non_exit_status(:ok), do: :still_running
  defp non_exit_status(_stop_result), do: :kill_failed

  defp shell_identity?(stage) do
    Enum.any?(
      [
        Map.get(stage, :headless_process_group_id),
        Map.get(stage, :headless_os_pid),
        Map.get(stage, :repl_os_pid)
      ],
      &(is_integer(&1) and &1 > 0)
    )
  end

  defp shell_alive?(stage) do
    group_alive? = ProcessTree.process_group_alive?(Map.get(stage, :headless_process_group_id))
    headless_alive? = ProcessTree.process_alive?(Map.get(stage, :headless_os_pid))
    repl_alive? = ProcessTree.process_alive?(Map.get(stage, :repl_os_pid))
    group_alive? or headless_alive? or repl_alive?
  end

  defp shell_alive(shell_alive_fun, stage) do
    case shell_alive_fun.(stage) do
      alive? when is_boolean(alive?) -> alive?
      _other -> :unknown
    end
  catch
    _kind, _reason -> :unknown
  end

  defp await_shell_exit(shell_alive_fun, stage, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + max(timeout_ms, 0)
    do_await_shell_exit(shell_alive_fun, stage, deadline)
  end

  defp do_await_shell_exit(shell_alive_fun, stage, deadline) do
    case shell_alive(shell_alive_fun, stage) do
      false ->
        :gone

      :unknown ->
        :unknown

      true ->
        if System.monotonic_time(:millisecond) >= deadline do
          :alive
        else
          Process.sleep(@os_exit_poll_ms)
          do_await_shell_exit(shell_alive_fun, stage, deadline)
        end
    end
  end

  defp request_reap(reap_fun, stage) do
    reap_fun.(stage)
  catch
    _kind, _reason -> {:error, :reap_failed}
  end

  defp exit_status(:normal), do: "normal"
  defp exit_status(:shutdown), do: "shutdown"
  defp exit_status({:shutdown, _reason}), do: "shutdown"
  defp exit_status(:killed), do: "killed"
  defp exit_status(:noproc), do: "noproc"
  defp exit_status(_reason), do: "unknown"

  @doc false
  @spec now(keyword()) :: DateTime.t()
  def now(opts) do
    opts
    |> Keyword.get(:now_fun, &DateTime.utc_now/0)
    |> then(& &1.())
  end
end
