defmodule Aiur.AgentResourceGuard.BusyLoop do
  @moduledoc """
  Behavioural detection of CPU busy loops such as `sh -c 'while :; do :; done'`.

  A process is spinning when, between two samples, it burned CPU while staying
  runnable, made no read/write syscall and took no new page fault. A share of
  one core is deliberately not the test: on a saturated host a busy loop is
  starved well below 100%, which is exactly when it must still be recognised.
  Compilers and test runs allocate or do I/O, so they never hold the signature.
  """

  @type key :: {pos_integer(), String.t()}
  @type sample :: %{pid: pos_integer(), start: String.t(), state: String.t(), cpu: non_neg_integer(), minflt: non_neg_integer(), io: non_neg_integer()}
  @type tracked :: %{key() => map()}

  @doc "Reads one process sample from procfs; `nil` when the process is gone or unreadable."
  @spec sample(pos_integer(), Path.t()) :: sample() | nil
  def sample(pid, proc_dir \\ "/proc") when is_integer(pid) and pid > 0 do
    dir = Path.join(proc_dir, Integer.to_string(pid))

    with {:ok, stat} <- File.read(Path.join(dir, "stat")),
         {:ok, io} <- File.read(Path.join(dir, "io")),
         # comm may contain spaces and parens, so fields start after the last ")".
         [_comm, rest] <- :binary.split(stat, ") ", [:global]) |> split_last(),
         fields when length(fields) >= 20 <- String.split(rest),
         {:ok, io_calls} <- io_calls(io) do
      %{
        pid: pid,
        state: Enum.at(fields, 0),
        minflt: String.to_integer(Enum.at(fields, 7)),
        cpu: String.to_integer(Enum.at(fields, 11)) + String.to_integer(Enum.at(fields, 12)),
        start: Enum.at(fields, 19),
        io: io_calls
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Folds this tick's samples into the tracked history and returns the pids that
  have been spinning for at least `window_ms`. Processes absent from `samples`
  are forgotten, and the pid+start-time key keeps a recycled pid from
  inheriting another process's history.
  """
  @spec advance(tracked(), [sample()], integer(), non_neg_integer()) :: {MapSet.t(pos_integer()), tracked()}
  def advance(tracked, samples, now_ms, window_ms) do
    next =
      Map.new(samples, fn sample ->
        prev = Map.get(tracked, {sample.pid, sample.start})
        since = if spinning?(prev, sample), do: prev.since || prev.at
        {{sample.pid, sample.start}, sample |> Map.put(:at, now_ms) |> Map.put(:since, since)}
      end)

    busy = for {{pid, _start}, %{since: since}} <- next, is_integer(since), now_ms - since >= window_ms, into: MapSet.new(), do: pid
    {busy, next}
  end

  defp spinning?(nil, _sample), do: false

  defp spinning?(prev, sample),
    do: sample.state == "R" and sample.cpu > prev.cpu and sample.io == prev.io and sample.minflt == prev.minflt

  defp split_last(parts) when length(parts) >= 2, do: [Enum.drop(parts, -1), List.last(parts)]
  defp split_last(_parts), do: nil

  defp io_calls(io) do
    counts = for line <- String.split(io, "\n"), [key, value] <- [String.split(line, ": ")], key in ["syscr", "syscw"], do: String.to_integer(value)
    if length(counts) == 2, do: {:ok, Enum.sum(counts)}, else: :error
  end
end
