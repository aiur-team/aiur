defmodule Aiur.DecisionMetricsWriterTest do
  use ExUnit.Case, async: false

  alias Aiur.DecisionMetrics
  alias Aiur.DecisionMetrics.{Log, Sample, Writer}

  @moduletag :tmp_dir
  @requested_at ~U[2026-07-12 12:00:00.000Z]

  test "bounds samples, dedup identities, and the compacted stream", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "bounded.ndjson")

    writer =
      start_writer!(path,
        sample_limit: 3,
        record_limit: 5,
        seen_limit: 4,
        flush_interval_ms: 60_000
      )

    for number <- 1..12, do: Writer.persist(record(number), writer)
    assert :ok = Writer.flush(writer)

    assert %{
             sample_count: 3,
             seen_count: 4,
             pending_count: 0,
             record_count: record_count,
             force_compact?: false
           } = Writer.stats(writer)

    assert record_count <= 5
    assert path |> File.read!() |> String.split("\n", trim: true) |> length() <= 5
    assert map_size(Writer.load(writer).samples) == 3

    GenServer.stop(writer)

    replayed =
      start_writer!(path,
        sample_limit: 3,
        record_limit: 5,
        seen_limit: 4,
        flush_interval_ms: 60_000
      )

    assert map_size(Writer.load(replayed).samples) == 3
    assert Writer.stats(replayed).seen_count <= 4
  end

  test "replay reads only its configured tail", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "tail-bounded.ndjson")
    assert :ok = Log.prepare(path)
    File.write!(path, String.duplicate("oversized-prefix", 2_000) <> "\n", [:append])
    assert :ok = Log.append_batch(path, Enum.map(1..20, &record/1))

    replay = Log.replay(path, record_limit: 4, max_bytes: 4_000)

    assert replay.record_count == 4
    assert replay.truncated?
    assert map_size(replay.samples) == 4
    assert length(replay.event_ids) == 4
  end

  test "collector stays responsive while its writer is blocked", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "async-writer.ndjson")
    parent = self()
    writes = :counters.new(1, [])

    append_fun = fn append_path, records ->
      :counters.add(writes, 1, 1)

      if :counters.get(writes, 1) == 1 do
        send(parent, {:writer_blocked, self()})

        receive do
          :release_writer -> Log.append_batch(append_path, records)
        end
      else
        Log.append_batch(append_path, records)
      end
    end

    writer =
      start_writer!(path,
        append_fun: append_fun,
        flush_interval_ms: 1,
        batch_limit: 100
      )

    metrics = start_metrics!(writer)
    on_exit(fn -> send(writer, :release_writer) end)

    assert :ok = DecisionMetrics.observe(request_event(1, "dec-1"), metrics)
    assert_receive {:writer_blocked, ^writer}, 1_000

    assert :ok = DecisionMetrics.observe(request_event(2, "dec-2"), metrics)
    assert {:ok, _snapshot} = DecisionMetrics.snapshot("dec-2", metrics)

    send(writer, :release_writer)
    assert :ok = DecisionMetrics.flush(metrics)
  end

  test "failed append retains the latest projection for compaction retry", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "retry-after-write-failure.ndjson")

    writer =
      start_writer!(path,
        append_fun: fn _path, _records -> {:error, :disk_full} end,
        flush_interval_ms: 60_000
      )

    Writer.persist(record(1), writer)
    assert {:error, :disk_full} = Writer.flush(writer)
    assert Writer.stats(writer).force_compact?

    assert :ok = Writer.flush(writer)
    refute Writer.stats(writer).force_compact?
    assert path |> File.read!() |> String.split("\n", trim: true) |> length() == 1
  end

  test "canonical seeding does not block startup or event collection", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "async-seed.ndjson")
    parent = self()

    seed_fun = fn _store, _limit ->
      send(parent, {:seed_blocked, self()})

      receive do
        :release_seed -> %{events: [], attention_index: %{}}
      end
    end

    {:ok, metrics} =
      DecisionMetrics.start_link(
        name: nil,
        path: path,
        subscribe?: false,
        seed?: true,
        seed_fun: seed_fun
      )

    on_exit(fn -> Aiur.TestSupport.safe_stop(metrics) end)
    assert_receive {:seed_blocked, seed_task}, 1_000

    assert :ok = DecisionMetrics.observe(request_event(3, "dec-live"), metrics)
    assert {:ok, _snapshot} = DecisionMetrics.snapshot("dec-live", metrics)

    send(seed_task, :release_seed)
    assert :ok = DecisionMetrics.await_seed(metrics)
  end

  test "canonical seed failure is observable without stopping collection", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "failed-seed.ndjson")

    {:ok, metrics} =
      DecisionMetrics.start_link(
        name: nil,
        path: path,
        subscribe?: false,
        seed_fun: fn _store, _limit -> raise "seed unavailable" end
      )

    on_exit(fn -> Aiur.TestSupport.safe_stop(metrics) end)
    assert {:error, {:exception, "seed unavailable"}} = DecisionMetrics.await_seed(metrics)
    assert :ok = DecisionMetrics.observe(request_event(4, "dec-after-failed-seed"), metrics)
    assert {:ok, _snapshot} = DecisionMetrics.snapshot("dec-after-failed-seed", metrics)
  end

  defp start_writer!(path, opts) do
    {:ok, writer} = Writer.start_link(Keyword.merge(opts, name: nil, path: path))
    on_exit(fn -> Aiur.TestSupport.safe_stop(writer) end)
    writer
  end

  defp start_metrics!(writer) do
    {:ok, metrics} =
      DecisionMetrics.start_link(name: nil, writer: writer, subscribe?: false, seed?: false)

    on_exit(fn -> Aiur.TestSupport.safe_stop(metrics) end)
    metrics
  end

  defp record(number) do
    decision_id = "dec-#{number}"
    identifier = Integer.to_string(number)
    at = DateTime.add(@requested_at, number, :second)

    sample =
      decision_id
      |> Sample.new(identifier)
      |> Sample.observe(:requested, %{at: at, blocking: true})

    Log.record(
      sample,
      %{event_id: "event-#{number}", stage: :requested, decision_id: decision_id, identifier: identifier},
      at
    )
  end

  defp request_event(id, decision_id) do
    %{
      id: "canonical:test:#{id}",
      topic: "ticket.42.agent.decision.requested",
      decision_id: decision_id,
      blocking: true,
      created_at: DateTime.to_iso8601(@requested_at)
    }
  end
end
