defmodule Aiur.Orchestrator.StatusCLI.Sections do
  @moduledoc false
  # Every `aiur status` section after the fleet table reads another daemon
  # process. Read one after another, a few slow replies under host load summed
  # to 9s while `agents` answered in 2s (#5817). The sections now run
  # concurrently under one shared deadline, and a section that misses it is
  # rendered from its last good output, labelled with that output's age.

  alias Aiur.Orchestrator.SnapshotCache
  alias Aiur.Protocol.ObservationAge

  @type outcome :: {:ok, term()} | {:stale, term()} | :unavailable

  @spec start([{atom(), (-> term())}]) :: [{atom(), Task.t()}]
  def start(sections), do: Enum.map(sections, fn {name, fun} -> {name, Task.async(fn -> capture(fun) end)} end)

  @doc "Prints each section in order by `deadline_ms` (monotonic) and returns its outcome."
  @spec await([{atom(), Task.t()}], integer(), pos_integer()) :: [{atom(), outcome()}]
  def await(started, deadline_ms, bound_ms) do
    Enum.map(started, fn {name, task} ->
      remaining = max(deadline_ms - System.monotonic_time(:millisecond), 0)
      {name, render(name, Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill), bound_ms)}
    end)
  end

  defp render(name, {:ok, {output, {:ok, value}}}, _bound_ms) do
    remember(name, %{output: output, value: value, at_ms: System.monotonic_time(:millisecond)})
    IO.write(output)
    {:ok, value}
  end

  # A section that crashed fails the whole command, as it did when it ran
  # inline: `guarded/2` turns it into one error line and an exit marker (#1684).
  defp render(_name, {:ok, {output, {:raise, kind, payload, stacktrace}}}, _bound_ms) do
    IO.write(output)
    :erlang.raise(kind, payload, stacktrace)
  end

  defp render(name, _timed_out, bound_ms) do
    case last_good(name) do
      %{output: output, value: value, at_ms: at_ms} ->
        age_seconds = div(System.monotonic_time(:millisecond) - at_ms, 1_000)

        IO.puts("STALE #{label(name)} — showing the last good output, #{ObservationAge.short_label(age_seconds)} old (no reply within #{bound_ms}ms)")

        IO.write(output)
        {:stale, value}

      nil ->
        IO.puts("#{label(name)} unavailable (no reply within #{bound_ms}ms and no earlier output)")
        :unavailable
    end
  end

  defp capture(fun) do
    {:ok, io} = StringIO.open("")
    Process.group_leader(self(), io)

    value =
      try do
        {:ok, fun.()}
      catch
        kind, payload -> {:raise, kind, payload, __STACKTRACE__}
      end

    {:ok, {_input, output}} = StringIO.close(io)
    {output, value}
  end

  defp label(name), do: name |> Atom.to_string() |> String.replace("_", " ") |> String.upcase()

  # The cache table outlives the RPC evaluator that runs each `status` call.
  defp remember(name, entry) do
    SnapshotCache.put({:status_section, name}, entry)
  rescue
    ArgumentError -> false
  end

  defp last_good(name), do: SnapshotCache.get({:status_section, name})
end
