defmodule Aiur.Workspace.WipPreservation.Command do
  @moduledoc """
  Runs one external command of an uncommitted-work save with a hard time
  limit (#2743).

  `System.cmd/3` has no timeout, and a `git` or `tar` run over a huge or
  hung checkout could block its caller without end. This runner kills the
  OS process with `SIGKILL` when the limit expires and returns
  `{:error, {:command_timeout, command, args, timeout_ms}}`.
  """

  @type result :: {:ok, {binary(), non_neg_integer()}} | {:error, term()}

  @doc """
  Runs `command` with `args`. Options: `:timeout_ms` (required), `:env` (a
  list of `{name, value}` string pairs) and `:stderr_to_stdout` (default
  `false`; stderr is then inherited, as with `System.cmd/3`).
  """
  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(command, args, opts) when is_binary(command) and is_list(args) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)

    case executable(command) do
      nil -> {:error, {:command_not_found, command}}
      path -> spawn_and_collect(path, command, args, timeout_ms, opts)
    end
  end

  @doc "True when `reason` is the timeout error of `run/3`."
  @spec timeout?(term()) :: boolean()
  def timeout?({:command_timeout, _command, _args, _timeout_ms}), do: true
  def timeout?(_reason), do: false

  defp executable(command) do
    if Path.type(command) == :absolute,
      do: if(File.regular?(command), do: command),
      else: System.find_executable(command)
  end

  defp spawn_and_collect(path, command, args, timeout_ms, opts) do
    port_opts =
      [:binary, :exit_status, :hide, :use_stdio, args: args, env: port_env(Keyword.get(opts, :env, []))] ++
        if(Keyword.get(opts, :stderr_to_stdout, false), do: [:stderr_to_stdout], else: [])

    port = Port.open({:spawn_executable, path}, port_opts)

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(port, os_pid, deadline, [], {command, Enum.take(args, 4), timeout_ms})
  rescue
    error -> {:error, {:command_failed_to_start, command, Exception.message(error)}}
  end

  defp collect(port, os_pid, deadline, acc, {command, args, timeout_ms} = context) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect(port, os_pid, deadline, [acc, data], context)
      {^port, {:exit_status, status}} -> {:ok, {IO.iodata_to_binary(acc), status}}
    after
      remaining ->
        kill(port, os_pid)
        {:error, {:command_timeout, command, args, timeout_ms}}
    end
  end

  defp kill(port, os_pid) do
    if is_integer(os_pid), do: System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    catch
      :error, :badarg -> :ok
    end

    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp port_env(env), do: Enum.map(env, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)
end
