defmodule VoiceConverse.AgentFork.OsProcess do
  @moduledoc false
  # One fork child as a port. The runtime starts each port child as the leader of its own
  # process group, so its OS pid is the group id and killing the group also kills grandchildren.

  @max_line 4_194_304

  @spec open(Path.t(), [String.t()], list(), Path.t()) :: {port(), pos_integer() | nil}
  def open(exe, args, env, cwd) do
    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        :stderr_to_stdout,
        {:line, @max_line},
        args: args,
        env: env,
        cd: cwd
      ])

    # A child that exits at once has closed its port already; its exit status is in the mailbox.
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> {port, os_pid}
      nil -> {port, nil}
    end
  end

  @spec send_json(port(), map()) :: true
  def send_json(port, message), do: Port.command(port, [Jason.encode_to_iodata!(message), ?\n])

  @doc """
  Feeds each JSON line to `handler.(message, acc)` until it returns `{:halt, result}`. Non-JSON
  lines are skipped. Ends early with `{:error, :timeout | :caller_down | {:exited, status}}`.
  """
  @spec collect(port(), map(), acc, (map(), acc -> {:cont, acc} | {:halt, term()})) :: term() when acc: term()
  def collect(port, ctx, acc, handler), do: collect(port, ctx, acc, handler, "")

  defp collect(port, %{deadline: deadline, watch: watch} = ctx, acc, handler, buffer) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        collect(port, ctx, acc, handler, buffer <> chunk)

      {^port, {:data, {:eol, chunk}}} ->
        case Jason.decode(buffer <> chunk) do
          {:ok, %{} = message} ->
            case handler.(message, acc) do
              {:cont, acc} -> collect(port, ctx, acc, handler, "")
              {:halt, result} -> result
            end

          _ ->
            collect(port, ctx, acc, handler, "")
        end

      {^port, {:exit_status, status}} ->
        {:error, {:exited, status}}

      {:DOWN, ^watch, :process, _, _} ->
        {:error, :caller_down}
    after
      remaining -> {:error, :timeout}
    end
  end

  @doc """
  Runs `exe` to exit within `timeout_ms` and returns its output; on timeout the group is killed.
  """
  @spec run(Path.t(), [String.t()], list(), Path.t(), pos_integer()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, :timeout}
  def run(exe, args, env, cwd, timeout_ms) do
    {port, os_pid} = open(exe, args, env, cwd)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      read_all(port, deadline, [])
    after
      stop(port, os_pid)
    end
  end

  defp read_all(port, deadline, acc) do
    receive do
      {^port, {:data, {:eol, chunk}}} -> read_all(port, deadline, [acc, chunk, ?\n])
      {^port, {:data, {:noeol, chunk}}} -> read_all(port, deadline, [acc, chunk])
      {^port, {:exit_status, status}} -> {:ok, IO.iodata_to_binary(acc), status}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :timeout}
    end
  end

  @doc """
  Kills the child's whole process group and closes the port. The kill is sent even after the
  child exited: its grandchildren (a stray tool or hook process) may still be in the group, and
  the group id is not reused while any of them lives. Only after the group is empty could a new
  group leader get the same id; the kill follows the exit at once, so that window is accepted.
  """
  @spec stop(port(), pos_integer() | nil) :: :ok
  def stop(port, os_pid) do
    kill_group(os_pid)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @spec kill_group(pos_integer() | nil) :: :ok
  def kill_group(nil), do: :ok

  def kill_group(os_pid) do
    System.cmd("kill", ["-s", "KILL", "--", "-#{os_pid}"], stderr_to_stdout: true)
    :ok
  end
end
