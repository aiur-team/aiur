defmodule Aiur.AgentResourceGuard.RunawayGroups do
  @moduledoc """
  Counts host process groups running one command over and over, and alerts.

  A wrapper that execs itself builds a chain of thousands of identical
  processes inside a single process group. On 2026-10-10 three such groups of
  the agent `git` wrapper reached 12-14k processes each and exhausted the host
  (#4205). Nothing legitimate runs a thousand copies of one command in one
  group, so the count alone identifies the runaway. The scan only reports: the
  alert names the group so the Executor can clear it with `kill -9 -- -<pgid>`.
  """

  require Logger

  @alert "system.host.runaway_process_group"
  @threshold 1_000
  @interval_ms 30_000

  @type group :: %{pgid: pos_integer(), comm: String.t(), count: pos_integer()}

  @doc "Process groups holding more than `:threshold` processes of one command."
  @spec scan(keyword()) :: [group()]
  def scan(opts \\ []) do
    proc_root = Keyword.get(opts, :proc_root, "/proc")
    threshold = Keyword.get(opts, :threshold, @threshold)

    case File.ls(proc_root) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(&group_key(proc_root, &1))
        |> Enum.frequencies()
        |> Enum.flat_map(fn
          {{pgid, comm}, count} when count > threshold -> [%{pgid: pgid, comm: comm, count: count}]
          _other -> []
        end)
        |> Enum.sort_by(&{-&1.count, &1.pgid})

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Scans at most once per interval and alerts once per runaway group.

  Throttle and already-alerted groups live in the calling process's
  dictionary, so the guard's tick can call this every second.
  """
  @spec check(keyword()) :: [group()]
  def check(opts \\ []) do
    now = System.monotonic_time(:millisecond)
    last = Process.get({__MODULE__, :scanned_at})

    if is_nil(last) or now - last >= Keyword.get(opts, :interval_ms, @interval_ms) do
      Process.put({__MODULE__, :scanned_at}, now)
      groups = scan(opts)
      alerted = Process.get({__MODULE__, :alerted}, MapSet.new())
      emit_fun = Keyword.get(opts, :emit_fun, &Aiur.Signal.alert/2)

      fresh = Enum.reject(groups, &MapSet.member?(alerted, {&1.pgid, &1.comm}))
      Enum.each(fresh, &alert(&1, emit_fun))
      # Forget groups that are gone so a recurrence alerts again.
      Process.put({__MODULE__, :alerted}, MapSet.new(groups, &{&1.pgid, &1.comm}))
      fresh
    else
      []
    end
  end

  defp alert(%{pgid: pgid, comm: comm, count: count}, emit_fun) do
    message = "Runaway process group #{pgid}: #{count} `#{comm}` processes"
    Logger.error("runaway_process_group pgid=#{pgid} comm=#{comm} count=#{count}")

    emit_fun.(@alert,
      message: message,
      reason:
        message <>
          ". One command repeated this many times in a single process group is a self-spawning chain that will exhaust the host. " <>
          "Killing by pid loses the race; clear the whole group with `kill -9 -- -#{pgid}`.",
      needs_attention: true,
      severity: "critical"
    )
  end

  # `/proc/<pid>/stat` is `pid (comm) state ppid pgrp ...`; comm may itself
  # contain spaces and parentheses, so match greedily to the last `)`.
  defp group_key(proc_root, entry) do
    with {_pid, ""} <- Integer.parse(entry),
         {:ok, stat} <- File.read(Path.join([proc_root, entry, "stat"])),
         [_all, comm, pgid] <- Regex.run(~r/^\d+ \((.*)\) \S -?\d+ (\d+) /s, stat) do
      [{String.to_integer(pgid), comm}]
    else
      _other -> []
    end
  end
end
