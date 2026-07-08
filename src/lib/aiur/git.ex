defmodule Aiur.Git do
  @moduledoc """
  Thin wrappers around git shell-outs used by Aiur subsystems that need
  out-of-band access to a remote's refs without making a GitHub REST call.

  Why exist: `git ls-remote` is the only reliable way to detect a branch
  push within seconds (the GitHub `/events` firehose lag is 30-120 seconds
  on a quiet repo). `Aiur.Events.Publisher` calls this helper on every
  poll tick for the set of running-branch refs and dedupes results against
  the firehose by `(repo, ref, sha)` so the firehose is canonical for
  payload shape, ls-remote just races the firehose for latency.
  """

  alias Aiur.Claude.RemoteControl

  require Logger

  @default_ls_remote_timeout_ms 10_000

  @typedoc """
  Result of `ls_remote/2`. Maps each `refs/heads/<branch>` ref to the SHA
  the remote currently holds. Refs the remote doesn't carry are absent
  from the map (no error).
  """
  @type refs_map :: %{String.t() => String.t()}

  @doc """
  Returns a map of `ref => sha` for each ref listed in `refs` that the
  `remote` currently exposes. Empty map if none match. Returns
  `{:error, reason}` if the `git` binary is missing or the command fails.

  Accepts a `cmd_fun:` option that takes a `{git_path, args}` tuple and
  returns `{stdout, exit_code}` — used by tests to inject a stub instead
  of shelling out. Production shell-outs are bounded by `:timeout_ms` and
  kill the spawned process tree if the remote call hangs.
  """
  @spec ls_remote(String.t(), [String.t()], keyword()) :: {:ok, refs_map()} | {:error, term()}
  def ls_remote(remote, refs, opts \\ []) when is_binary(remote) and is_list(refs) do
    cmd_fun = Keyword.get(opts, :cmd_fun) || default_cmd_fun(opts)
    git_path = Keyword.get(opts, :git_path) || System.find_executable("git")

    cond do
      git_path == nil and not Keyword.has_key?(opts, :cmd_fun) ->
        {:error, :git_not_found}

      refs == [] ->
        {:ok, %{}}

      true ->
        do_ls_remote(cmd_fun, git_path, remote, refs)
    end
  end

  defp do_ls_remote(cmd_fun, git_path, remote, refs) do
    case cmd_fun.({git_path, ["ls-remote", remote | refs]}) do
      {output, 0} ->
        {:ok, parse_output(output)}

      {output, exit_code} ->
        {:error, {:git_ls_remote_failed, exit_code, String.trim(output)}}

      {:timeout, timeout_ms, output} ->
        {:error, {:git_ls_remote_timeout, timeout_ms, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_ls_remote_exception, Exception.message(error)}}
  end

  defp default_cmd_fun(opts) do
    timeout_ms = normalize_timeout_ms(Keyword.get(opts, :timeout_ms, @default_ls_remote_timeout_ms))
    kill_tree_fun = Keyword.get(opts, :kill_tree_fun, &RemoteControl.graceful_kill_tree/1)

    fn {git_path, args} ->
      run_bounded_cmd(git_path, args, timeout_ms, kill_tree_fun)
    end
  end

  defp normalize_timeout_ms(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: timeout_ms

  defp normalize_timeout_ms(_timeout_ms), do: @default_ls_remote_timeout_ms

  defp run_bounded_cmd(git_path, args, timeout_ms, kill_tree_fun) do
    port =
      Port.open({:spawn_executable, git_path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args
      ])

    os_pid = port_os_pid(port)
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    collect_cmd_output(port, [], deadline_ms, timeout_ms, kill_tree_fun, os_pid)
  end

  defp collect_cmd_output(port, chunks, deadline_ms, timeout_ms, kill_tree_fun, os_pid) do
    receive do
      {^port, {:data, data}} ->
        collect_cmd_output(port, [data | chunks], deadline_ms, timeout_ms, kill_tree_fun, os_pid)

      {^port, {:exit_status, status}} ->
        {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      remaining_timeout_ms(deadline_ms) ->
        kill_tree_fun.(os_pid)
        close_port(port)
        {:timeout, timeout_ms, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp remaining_timeout_ms(deadline_ms) do
    max(deadline_ms - System.monotonic_time(:millisecond), 0)
  end

  defp port_os_pid(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      _ -> nil
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  defp parse_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ~r/\s+/, parts: 2) do
        [sha, ref] -> Map.put(acc, ref, sha)
        _ -> acc
      end
    end)
  end

  @doc """
  The `owner/name` of the `origin` remote in the current working directory,
  or `nil` when there is no git repo / origin. Used to auto-detect the repo
  for a global `.aiurconfig` that carries no repo of its own.
  """
  @spec origin_repo() :: String.t() | nil
  def origin_repo do
    case System.cmd("git", ["remote", "get-url", "origin"], stderr_to_stdout: true) do
      {output, 0} -> parse_origin_url(String.trim(output))
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc false
  @spec parse_origin_url(String.t()) :: String.t() | nil
  def parse_origin_url(url) do
    url
    |> String.replace_suffix(".git", "")
    |> String.split(~r{[/:]}, trim: true)
    |> Enum.take(-2)
    |> case do
      [owner, name] when owner != "" and name != "" -> "#{owner}/#{name}"
      _ -> nil
    end
  end
end
