defmodule Aiur.ControlCLI.Protocol do
  @moduledoc false
  alias Aiur.Orchestrator

  @exit_marker "__AIUR_CONTROL_EXIT__:"
  @error_marker "__AIUR_CONTROL_ERROR__:"

  @doc false
  @spec error_marker() :: String.t()
  def error_marker, do: @error_marker

  @doc false
  @spec exit_marker() :: String.t()
  def exit_marker, do: @exit_marker

  # The old wording said "daemon may be scheduler-saturated". That is a cause,
  # confidently asserted, that this code has no evidence for — and in #1731 it
  # was wrong: the run queue was 1, the host was fine, and one process was
  # head-of-line blocked. A wrong diagnosis printed with confidence is worse
  # than none; it sends the operator to look at host load.
  #
  # So report only what is observable here: which query did not answer, and the
  # state of the process that owed the answer. `Process.info/2` reads the
  # target's mailbox and current function without needing it to be scheduled,
  # which is exactly the measurement an operator would otherwise take by hand.
  #
  # "outcome is unknown" is kept verbatim from #1720/#1812: it is a *different*
  # claim from this one — that the command may or may not have taken effect —
  # and the operator needs both. This adds the evidence, it does not replace it.
  defp print_control_query_error(:timeout, query, timeout_ms) do
    IO.puts(
      "#{@error_marker}aiur: #{query} query timed out after #{format_timeout_budget(timeout_ms)}" <>
        "; outcome is unknown. #{orchestrator_liveness()}"
    )
  end

  defp print_control_query_error(:unavailable, query, _timeout_ms) do
    IO.puts("#{@error_marker}aiur: #{query} query failed because the orchestrator is not running")
  end

  @doc false
  @spec orchestrator_liveness() :: String.t()
  def orchestrator_liveness do
    case Process.whereis(Orchestrator) do
      nil ->
        "The orchestrator process is not registered, so the daemon is down or still starting."

      pid ->
        describe_orchestrator(Process.info(pid, [:message_queue_len, :status, :current_function]))
    end
  end

  defp describe_orchestrator(nil), do: "The orchestrator process has exited."

  defp describe_orchestrator(info) do
    "Orchestrator mailbox=#{Keyword.get(info, :message_queue_len)} status=#{Keyword.get(info, :status)}" <>
      " in #{format_mfa(Keyword.get(info, :current_function))}. " <>
      "A large mailbox or a blocked current function means one process is stuck, not that the host is busy."
  end

  defp format_mfa({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"
  defp format_mfa(_other), do: "an unknown function"

  @doc false
  @spec control_query_exit_code(term()) :: 1 | 124
  def control_query_exit_code(:timeout), do: 124
  def control_query_exit_code(_error), do: 1

  @doc false
  @spec report_control_query_failure(atom(), String.t(), pos_integer()) :: :ok
  def report_control_query_failure(error, query, timeout_ms) do
    print_control_query_error(error, query, timeout_ms)
    exit_marker(control_query_exit_code(error))
  end

  # Last-resort guard for the read-only query commands (#1684). An unexpected
  # raise or process exit inside a command body used to kill the RPC evaluator
  # outright, and the operator saw a non-zero exit with an empty buffer — the
  # one failure mode indistinguishable from a healthy idle fleet. Whatever goes
  # wrong, the command now says what failed in one line and still emits an exit
  # marker, so the launcher never has to guess.
  @doc false
  @spec guarded(String.t(), (-> :ok)) :: :ok
  def guarded(query, fun) do
    fun.()
  rescue
    error -> report_control_query_crash(query, Exception.message(error))
  catch
    :exit, {:timeout, {GenServer, :call, [_server, _request, timeout_ms]}}
    when is_integer(timeout_ms) ->
      print_control_query_error(:timeout, query, timeout_ms)
      exit_marker(control_query_exit_code(:timeout))

    :exit, reason ->
      report_control_query_crash(query, "process exited: #{inspect(reason)}")

    kind, payload ->
      report_control_query_crash(query, "#{kind}: #{inspect(payload)}")
  end

  defp report_control_query_crash(query, detail) do
    IO.puts("#{@error_marker}aiur: #{query} query failed (#{single_line(detail)})")
    exit_marker(1)
  end

  @doc false
  @spec single_line(term()) :: String.t()
  def single_line(text) do
    text |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 300)
  end

  @doc false
  @spec control_query_timeout(keyword(), atom(), pos_integer()) :: pos_integer()
  def control_query_timeout(opts, key, default) do
    case Keyword.get(opts, key, default) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _invalid -> default
    end
  end

  @doc false
  @spec format_timeout_budget(pos_integer()) :: String.t()
  def format_timeout_budget(timeout_ms) when rem(timeout_ms, 1_000) == 0,
    do: "#{div(timeout_ms, 1_000)}s"

  def format_timeout_budget(timeout_ms), do: "#{timeout_ms}ms"

  @doc false
  @spec application_started?() :: boolean()
  def application_started? do
    Enum.any?(Application.started_applications(), fn {app, _description, _version} ->
      app == :aiur
    end)
  end

  @doc false
  @spec not_running_message() :: String.t()
  def not_running_message do
    "error: aiur is not running. Start it with `aiurdev run` (or `aiurdev --bg`), then retry."
  end

  @doc false
  @spec control_error(String.t()) :: :ok
  def control_error(message) do
    message = single_line(message)
    IO.puts(:stderr, message)
    IO.puts("#{@error_marker}#{message}")
  end

  @doc false
  @spec exit_marker(integer()) :: :ok
  def exit_marker(code) do
    IO.puts("#{@exit_marker}#{code}")
    :ok
  end
end
