defmodule Aiur.ProcessTree do
  @moduledoc "OS process signalling, subtree cleanup and identity-checked reaping."

  @kill_grace_ms 2_000
  @kill_poll_ms 25

  @spec kill_grace_ms() :: pos_integer()
  def kill_grace_ms, do: @kill_grace_ms

  # ----------------------------------------------------------------- kill

  @doc false
  # SIGTERM the process and block until it actually exits, escalating to
  # SIGKILL if it overstays.
  @spec graceful_kill(nil | integer()) :: :ok
  def graceful_kill(nil), do: :ok

  def graceful_kill(os_pid) when is_integer(os_pid) do
    pid = Integer.to_string(os_pid)
    System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)

    unless await_exit(pid, @kill_grace_ms) do
      System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
      await_exit(pid, @kill_grace_ms)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc false
  # Like graceful_kill/1 but also reaps the process subtree. The headless
  # `claude` backend runs under a `bash -c` wrapper that does NOT exec, so
  # its `claude`/node grandchildren reparent to init when the bash pid dies
  # and would survive teardown. Descendants are snapshotted while the root is
  # still alive (once it dies the parent link is lost), then reaped deepest
  # first so their living parents can collect them before the root exits.
  @spec graceful_kill_tree(nil | integer()) :: :ok
  def graceful_kill_tree(nil), do: :ok

  def graceful_kill_tree(os_pid) when is_integer(os_pid) do
    descendants = collect_descendants(os_pid)
    descendants |> Enum.reverse() |> Enum.each(&graceful_kill/1)
    graceful_kill(os_pid)
    :ok
  end

  @doc false
  @spec process_tree(integer() | nil) :: [pos_integer()]
  def process_tree(os_pid) when is_integer(os_pid) and os_pid > 0,
    do: [os_pid | collect_descendants(os_pid)] |> Enum.uniq()

  def process_tree(_os_pid), do: []

  @doc false
  @spec process_group_alive?(nil | integer()) :: boolean()
  def process_group_alive?(process_group_id) when is_integer(process_group_id) and process_group_id > 0 do
    match?({_, 0}, System.cmd("kill", ["-0", "--", "-#{process_group_id}"], stderr_to_stdout: true))
  rescue
    # A genuine "group is gone" returns a non-zero exit, not an exception. An
    # exception means the probe itself could not run (e.g. port exhaustion under
    # load), so assume alive — reporting "gone" here would let containment claim
    # a false success without ever signalling the surviving group.
    _ -> true
  end

  def process_group_alive?(_process_group_id), do: false

  @doc false
  @spec process_group_for_pid(integer() | String.t() | nil) :: integer() | nil
  def process_group_for_pid(pid) when is_integer(pid) and pid > 0,
    do: process_group_for_pid(Integer.to_string(pid))

  def process_group_for_pid(pid) when is_binary(pid) do
    case System.find_executable("ps") do
      nil ->
        nil

      ps ->
        case await_process_group_leader(ps, pid, 20) do
          group when is_binary(group) -> String.to_integer(group)
          _ -> nil
        end
    end
  end

  def process_group_for_pid(_pid), do: nil

  @doc false
  @spec process_alive?(nil | integer()) :: boolean()
  def process_alive?(os_pid), do: Aiur.ProcessIdentity.alive?(os_pid)

  @doc false
  @spec process_identity(nil | integer()) :: {:ok, term()} | :gone | :unknown
  def process_identity(os_pid), do: Aiur.ProcessIdentity.resolve(os_pid)

  @doc false
  @spec graceful_kill_process_group(nil | integer()) :: {:ok, :gone | :reaped} | {:error, :group_alive}
  def graceful_kill_process_group(process_group_id) when is_integer(process_group_id) and process_group_id > 0 do
    if process_group_alive?(process_group_id) do
      signal_process_group(process_group_id, "-TERM")

      if await_process_group_exit(process_group_id, @kill_grace_ms) do
        {:ok, :reaped}
      else
        force_kill_process_group(process_group_id)
      end
    else
      {:ok, :gone}
    end
  rescue
    _ -> {:error, :group_alive}
  end

  def graceful_kill_process_group(_process_group_id), do: {:ok, :gone}

  @doc false
  @spec reap_process_group(nil | integer(), term()) :: {:ok, :gone | :reaped} | {:error, term()}
  def reap_process_group(process_group_id, expected_identity),
    do: reap_process_group(process_group_id, expected_identity, &pidfd_reap/3)

  @doc false
  @spec reap_process_group(nil | integer(), term(), (integer(), term(), :group -> term())) ::
          {:ok, :gone | :reaped} | {:error, term()}
  def reap_process_group(process_group_id, expected_identity, reaper) when is_function(reaper, 3),
    do: reap_with_identity(process_group_id, expected_identity, :group, reaper)

  @doc false
  @spec reap_process_tree(nil | integer(), term()) :: :ok | {:error, term()}
  def reap_process_tree(os_pid, expected_identity),
    do: reap_process_tree(os_pid, expected_identity, &pidfd_reap/3)

  @doc false
  @spec reap_process_tree(nil | integer(), term(), (integer(), term(), :tree -> term())) :: :ok | {:error, term()}
  def reap_process_tree(os_pid, expected_identity, reaper) when is_function(reaper, 3),
    do: reap_with_identity(os_pid, expected_identity, :tree, reaper) |> tree_reap_result()

  @doc false
  @spec reap_process(nil | integer(), term()) :: :ok | {:error, term()}
  def reap_process(os_pid, expected_identity),
    do: reap_process(os_pid, expected_identity, &pidfd_reap/3)

  @doc false
  @spec reap_process(nil | integer(), term(), (integer(), term(), :process -> term())) :: :ok | {:error, term()}
  def reap_process(os_pid, expected_identity, reaper) when is_function(reaper, 3),
    do: reap_with_identity(os_pid, expected_identity, :process, reaper) |> tree_reap_result()

  defp reap_with_identity(identifier, {:known, expected_identity}, kind, reaper)
       when is_integer(identifier) and identifier > 0 do
    reaper.(identifier, expected_identity, kind)
  rescue
    _ -> {:error, :identity_signal_failed}
  end

  defp reap_with_identity(_identifier, _expected_identity, _kind, _reaper), do: {:error, :identity_unverified}

  defp tree_reap_result({:ok, _outcome}), do: :ok
  defp tree_reap_result({:error, _reason} = error), do: error

  # A process's number can be recycled after an ordinary procfs check. The
  # helper opens a Linux pidfd before rechecking its procfs birth/session pair,
  # then sends TERM/KILL only through that descriptor. Unsupported hosts fail
  # closed: the guardian retains ownership rather than signalling a recycled
  # PID or PGID.
  defp pidfd_reap(identifier, {:procfs_birth_and_session, start_time, session}, kind) do
    with python when is_binary(python) <- System.find_executable("python3"),
         script when is_binary(script) <- pidfd_reaper_script(),
         {_, 0} <- System.cmd(python, [script, Atom.to_string(kind), Integer.to_string(identifier), start_time, session], stderr_to_stdout: true) do
      {:ok, :reaped}
    else
      _ -> {:error, :identity_signal_unavailable}
    end
  rescue
    _ -> {:error, :identity_signal_unavailable}
  end

  defp pidfd_reap(_identifier, _expected_identity, _kind), do: {:error, :identity_signal_unavailable}

  defp pidfd_reaper_script do
    path = :aiur |> :code.priv_dir() |> to_string() |> Path.join("pidfd_reap.py")
    if File.regular?(path), do: path
  end

  defp force_kill_process_group(process_group_id) do
    signal_process_group(process_group_id, "-KILL")

    if await_process_group_exit(process_group_id, @kill_grace_ms) do
      {:ok, :reaped}
    else
      {:error, :group_alive}
    end
  end

  defp signal_process_group(process_group_id, signal) do
    System.cmd("kill", [signal, "--", "-#{process_group_id}"], stderr_to_stdout: true)
    :ok
  end

  defp await_process_group_exit(process_group_id, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_await_process_group_exit(process_group_id, deadline)
  end

  defp do_await_process_group_exit(process_group_id, deadline) do
    cond do
      not process_group_alive?(process_group_id) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@kill_poll_ms)
        do_await_process_group_exit(process_group_id, deadline)
    end
  end

  defp collect_descendants(pid) when is_integer(pid) do
    children =
      case System.find_executable("pgrep") do
        nil ->
          []

        pgrep ->
          case System.cmd(pgrep, ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
            {out, 0} -> out |> String.split() |> Enum.map(&String.to_integer/1)
            _ -> []
          end
      end

    children ++ Enum.flat_map(children, &collect_descendants/1)
  end

  defp await_exit(pid, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_await_exit(pid, deadline)
  end

  defp await_process_group_leader(ps, pid, attempts) do
    process_group_id =
      case System.cmd(ps, ["-o", "pgid=", "-p", pid], stderr_to_stdout: true) do
        {out, 0} -> out |> String.trim() |> positive_pid_string()
        _ -> nil
      end

    cond do
      process_group_id == pid ->
        pid

      attempts <= 1 ->
        nil

      true ->
        Process.sleep(10)
        await_process_group_leader(ps, pid, attempts - 1)
    end
  end

  defp positive_pid_string(value) do
    case Integer.parse(value) do
      {pid, ""} when pid > 0 -> Integer.to_string(pid)
      _ -> nil
    end
  end

  defp do_await_exit(pid, deadline) do
    cond do
      not os_process_alive?(pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@kill_poll_ms)
        do_await_exit(pid, deadline)
    end
  end

  @doc false
  @spec os_process_alive?(String.t()) :: boolean()
  def os_process_alive?(pid) when is_binary(pid) do
    case System.find_executable("kill") do
      nil ->
        true

      kill ->
        match?({_, 0}, System.cmd(kill, ["-0", pid], stderr_to_stdout: true))
    end
  rescue
    _ -> true
  end
end
