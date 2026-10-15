defmodule Aiur.GitHub.ResourceStore.Memory do
  @moduledoc """
  The body-memory bound and the size report for `Aiur.GitHub.ResourceStore`.

  The store's retention window bounds how *long* a body is held, not how much
  is held at once, and its entry backstop is 100,000 entries of up to 256 KiB
  each — 25 GiB before it binds. `enforce/2` is the bound that is actually
  expressed in bytes: when the held bodies exceed `max_body_bytes/0` it sheds
  the least recently written ones until they fit.

  Shedding drops only `:data` and `:data_version`, never the entry. The `:etag`
  and the processed mark are state a later read is still entitled to — the mark
  is the publisher's only durable dedup gate — and they are two orders of
  magnitude smaller than the body beside them. `recorded_at_ms` is untouched, so
  a shed entry ages out of the retention sweep on its real clock. A reader that
  revalidates a shed entry is answered `304`, holds nothing, and re-reads
  unconditionally, which is the documented reader's half of the contract.

  Sizes are `:erlang.external_size/1` of the body: computed without allocating,
  and within a few percent of the JSON the checkpoint writes for it.
  """

  require Logger

  @table Aiur.GitHub.ResourceStore.Table
  @max_entries 100_000

  # Three times what the busiest observed daemon holds (43.9 MB across 6,768
  # entries, ~10 agents and ~130 open tickets, 2026-10-10), so it does not bind
  # in normal operation: a shed body costs its next reader a full-price GitHub
  # read, and a cap near the working set would trade memory for quota on every
  # sweep.
  @max_body_bytes 128 * 1024 * 1024

  @type stats :: %{
          entries: non_neg_integer(),
          bodies: non_neg_integer(),
          body_bytes: non_neg_integer(),
          max_body_bytes: pos_integer(),
          process_bytes: non_neg_integer() | nil,
          shed: non_neg_integer()
        }

  @doc "The body-byte cap: `:github_resource_store_max_body_bytes`, or 128 MiB."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes do
    case Application.get_env(:aiur, :github_resource_store_max_body_bytes) do
      bytes when is_integer(bytes) and bytes > 0 -> bytes
      _other -> @max_body_bytes
    end
  end

  @doc """
  Sheds the least recently written bodies until the table is inside both
  bounds, and reports what it holds afterwards.

  Runs in the store process on its sweep. Each victim is pinned to the exact
  object that was measured, so an entry a writer refreshed in the meantime no
  longer matches and keeps its new body.
  """
  @spec enforce(:ets.table(), keyword()) :: stats()
  def enforce(table, opts \\ []) do
    max_entries = Keyword.get(opts, :max_entries, @max_entries)
    max_bytes = Keyword.get_lazy(opts, :max_body_bytes, &max_body_bytes/0)

    rows = table |> measure() |> Enum.sort()
    overflow = length(rows) - max_entries
    total = rows |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    {victims, _remaining} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({[], total}, fn {{recorded_at, key, bytes}, index}, {victims, remaining} ->
        if bytes > 0 and (index < overflow or remaining > max_bytes) do
          {[{key, recorded_at, bytes} | victims], remaining - bytes}
        else
          {victims, remaining}
        end
      end)

    shed = Enum.filter(victims, fn {key, recorded_at, _bytes} -> shed?(table, key, recorded_at) end)

    if shed != [] do
      Logger.warning(
        "GitHub.ResourceStore exceeded #{max_entries} entries or #{max_bytes} body bytes " <>
          "(held #{length(rows)} entries, #{total} bytes); dropped bodies from #{length(shed)} oldest"
      )
    end

    shed_bytes = shed |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    stats = %{
      entries: length(rows),
      bodies: Enum.count(rows, &(elem(&1, 2) > 0)) - length(shed),
      body_bytes: total - shed_bytes,
      max_body_bytes: max_bytes,
      process_bytes: process_bytes(self()),
      shed: length(shed)
    }

    :telemetry.execute([:aiur, :github, :resource_store, :sweep], Map.delete(stats, :max_body_bytes), %{})
    stats
  end

  @doc "What the running store holds right now, or `:unavailable` when there is none."
  @spec stats(atom()) :: stats() | :unavailable
  def stats(table \\ @table) do
    rows = measure(table)

    %{
      entries: length(rows),
      bodies: Enum.count(rows, &(elem(&1, 2) > 0)),
      body_bytes: rows |> Enum.map(&elem(&1, 2)) |> Enum.sum(),
      max_body_bytes: max_body_bytes(),
      process_bytes: process_bytes(:ets.info(table, :owner)),
      shed: 0
    }
  rescue
    # No table, or one that died mid-fold: both mean there is nothing to report.
    ArgumentError -> :unavailable
  end

  @doc "Prints the `GITHUB RESOURCES` line of `aiur status`."
  @spec print_status(atom()) :: :ok
  def print_status(table \\ @table) do
    case stats(table) do
      :unavailable ->
        IO.puts("GITHUB RESOURCES unavailable (resource store is not running)")

      stats ->
        IO.puts(
          "GITHUB RESOURCES entries=#{stats.entries} bodies=#{stats.bodies} " <>
            "body_bytes=#{mib(stats.body_bytes)}/#{mib(stats.max_body_bytes)} process=#{mib(stats.process_bytes)}"
        )
    end
  end

  # One `{recorded_at_ms, key, body_bytes}` row per entry. `foldl/3` copies one
  # entry at a time, so the bodies are never all in this process at once.
  defp measure(table) do
    :ets.foldl(
      fn {key, entry}, rows -> [{Map.get(entry, :recorded_at_ms, 0), key, body_bytes(Map.get(entry, :data))} | rows] end,
      [],
      table
    )
  end

  defp body_bytes(nil), do: 0
  defp body_bytes(data), do: :erlang.external_size(data)

  defp shed?(table, key, recorded_at) do
    case :ets.lookup(table, key) do
      [{^key, entry}] when is_map_key(entry, :data) ->
        Map.get(entry, :recorded_at_ms, 0) == recorded_at and
          :ets.select_replace(table, [
            {{key, :"$1"}, [{:==, :"$1", {:const, entry}}], [{:const, {key, Map.drop(entry, [:data, :data_version])}}]}
          ]) == 1

      _gone_or_bodyless ->
        false
    end
  end

  defp process_bytes(pid) when is_pid(pid) do
    case Process.info(pid, :memory) do
      {:memory, bytes} -> bytes
      nil -> nil
    end
  end

  defp process_bytes(_owner), do: nil

  defp mib(nil), do: "unknown"
  defp mib(bytes), do: "#{Float.round(bytes / 1_048_576, 1)}MiB"
end
