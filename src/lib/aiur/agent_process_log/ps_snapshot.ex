defmodule Aiur.AgentProcessLog.PsSnapshot do
  @moduledoc false

  # `ps` snapshot and `/proc` cwd sources for the process sweep.

  @spec snapshot() :: %{optional(integer()) => map()}
  def snapshot do
    case System.find_executable("ps") do
      nil ->
        %{}

      ps ->
        ps_snapshot_with(ps)
    end
  rescue
    _ -> %{}
  end

  defp ps_snapshot_with(ps) do
    case System.cmd(ps, ["-eo", "pid=,ppid=,comm=,args="], stderr_to_stdout: true) do
      {out, 0} -> add_start_times(ps, parse_ps(out))
      _other -> %{}
    end
  end

  # A second `ps` pass reads each pid's start time (`lstart`), so a pid reused
  # inside one sweep window is distinguished from the process that previously
  # held it. When start times are unavailable the log degrades to pid-only
  # identity.
  defp add_start_times(ps, starts) do
    case System.cmd(ps, ["-eo", "pid=,lstart="], stderr_to_stdout: true) do
      {lstarts, 0} -> attach_start_times(starts, parse_lstarts(lstarts))
      _other -> starts
    end
  end

  defp attach_start_times(starts, lstart_by_pid) do
    Map.new(starts, fn {pid, info} ->
      {pid, Map.put(info, :start_time, Map.get(lstart_by_pid, pid))}
    end)
  end

  defp parse_ps(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_ps_line(line) do
        nil -> acc
        {pid, info} -> Map.put(acc, pid, info)
      end
    end)
  end

  defp parse_ps_line(line) do
    with [pid_s, ppid_s, comm | args] <- String.split(String.trim_leading(line), ~r/\s+/, parts: 4),
         {pid, ""} <- Integer.parse(pid_s),
         {ppid, ""} <- Integer.parse(ppid_s),
         true <- pid > 0 do
      {pid, %{pid: pid, ppid: ppid, comm: comm, cmdline: Enum.join(args, " ")}}
    else
      _invalid -> nil
    end
  end

  # `lstart` itself contains spaces (`Sat Aug  9 21:00:00 2026`), so it is
  # parsed as the whole remainder of the line after the pid. The raw string is
  # used as an identity, not a timestamp: a reused pid is distinguished by its
  # start time differing, which needs no timezone or locale parsing.
  defp parse_lstarts(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_lstart_line(line) do
        {pid, lstart} when is_integer(pid) -> Map.put(acc, pid, lstart)
        _invalid -> acc
      end
    end)
  end

  defp parse_lstart_line(line) do
    case String.split(String.trim_leading(line), ~r/\s+/, parts: 2) do
      [pid_s, lstart] -> parse_lstart_pid(pid_s, lstart)
      _malformed -> nil
    end
  end

  defp parse_lstart_pid(pid_s, lstart) do
    case Integer.parse(pid_s) do
      {pid, ""} when pid > 0 -> {pid, lstart}
      _invalid -> nil
    end
  end

  @spec proc_cwd(term()) :: String.t()
  def proc_cwd(pid) when is_integer(pid) and pid > 0 do
    case File.read_link("/proc/#{pid}/cwd") do
      {:ok, path} -> path
      _ -> ""
    end
  end

  def proc_cwd(_pid), do: ""
end
