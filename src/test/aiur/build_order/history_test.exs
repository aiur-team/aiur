defmodule Aiur.BuildOrder.HistoryTest do
  use ExUnit.Case, async: false
  import Bitwise
  require Aiur.TestSupport
  alias Aiur.BuildOrder.{History, Lifecycle, ProviderHealth}
  alias Aiur.BuildOrder.History.Row
  @name __MODULE__.Store
  @t ~U[2026-10-01 12:00:00Z]

  setup do
    dir = Aiur.TestSupport.tmp_root!("build-history")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, path: Path.join(dir, "history.json"), opts: [server: @name]}
  end

  defp start(dir, extra \\ []) do
    start_supervised!({History, Keyword.merge([name: @name, repository: "acme/widgets", state_dir: dir, flush_ms: 60_000], extra)}, restart: :temporary)
  end

  defp restart(dir) do
    stop_supervised!(@name)
    start(dir)
  end

  defp event(fields \\ %{}, number \\ 1, dt \\ @t, source \\ :backfill), do: %{number: number, observed_at: dt, source: source, fields: fields}

  defp row(opts, n \\ 1) do
    {:ok, [row], _health} = History.rows([n], opts)
    row
  end

  defp record(rows \\ []) do
    %{"version" => 1, "repository" => "acme/widgets", "status" => "ok", "complete" => false, "generation" => 1, "checkpoints" => %{"backfill" => nil, "closed_since" => nil}, "rows" => rows}
  end

  defp write(path, record), do: File.write!(path, Jason.encode!(record))

  test "V1 rows survive a restart", %{dir: dir, opts: opts} do
    start(dir)
    events = for n <- 1..3, do: event(%{title: "Ticket #{n}", node_id: "I_#{n}", agent_model: :none}, n)
    assert {:ok, _} = History.apply(events, opts)
    assert :ok = History.flush(opts)
    assert {:ok, before} = History.snapshot(opts)
    restart(dir)
    assert {:ok, after_restart} = History.snapshot(opts)
    assert after_restart.rows == before.rows
    assert after_restart.health.generation == before.health.generation
    assert before.health.last_success_at != nil
    assert after_restart.health.observed_at == @t
  end

  test "V2 checkpoint and rows share a crash boundary", %{dir: dir, opts: opts} do
    pid = start(dir)
    assert {:ok, _} = History.apply([event()], opts ++ [checkpoint: {:backfill, %{"page" => 3}}])
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    Aiur.TestSupport.receive_barrier({:DOWN, ^ref, :process, ^pid, :killed})
    start(dir)
    assert {:ok, [], _} = History.rows([1], opts)
    assert {:ok, nil} = History.checkpoint(:backfill, opts)
    assert {:ok, _} = History.apply([event()], opts ++ [checkpoint: {:backfill, %{"page" => 3}}])
    assert :ok = History.flush(opts)
    pid = Process.whereis(@name)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    Aiur.TestSupport.receive_barrier({:DOWN, ^ref, :process, ^pid, :killed})
    start(dir)
    assert row(opts).number == 1
    assert {:ok, %{"page" => 3}} = History.checkpoint(:backfill, opts)
  end

  test "V3 supervisor shutdown flushes inside debounce", %{dir: dir, opts: opts} do
    start(dir)
    History.apply([event(%{title: "saved"})], opts)
    restart(dir)
    assert row(opts).title == "saved"
  end

  test "V4 corrupt file reads unavailable and preserves evidence", %{dir: dir, path: path, opts: opts} do
    File.write!(path, "{not json")
    start(dir)
    assert {:error, %ProviderHealth{failure: :history_corrupt}} = History.snapshot(opts)
    assert [corrupt] = Path.wildcard(path <> ".corrupt-*")
    assert File.read!(corrupt) == "{not json"
  end

  test "V5 null row fails the whole file", %{dir: dir, path: path, opts: opts} do
    {:changed, r} = Row.merge(nil, event())
    write(path, record([Map.put(Row.to_json(r), "closed_at", nil)]))
    start(dir)
    assert {:error, %ProviderHealth{failure: :history_corrupt}} = History.snapshot(opts)
  end

  test "V6 rebuilding survives until mark_complete", %{dir: dir, path: path, opts: opts} do
    File.write!(path, "bad")
    start(dir)
    History.apply([event()], opts)
    History.flush(opts)
    restart(dir)
    assert {:error, %ProviderHealth{failure: :history_rebuilding, complete?: false}} = History.snapshot(opts)
    assert {:ok, nil} = History.checkpoint(:backfill, opts)
    assert :ok = History.mark_complete(opts)
    assert {:ok, %{rows: rows, health: %ProviderHealth{state: :healthy, complete?: true}}} = History.snapshot(opts)
    assert rows[1].number == 1
    restart(dir)
    assert History.health(opts).complete?
  end

  test "V7 newer version remains untouched", %{dir: dir, path: path, opts: opts} do
    write(path, %{record() | "version" => 2})
    bytes = File.read!(path)
    start(dir)
    assert {:error, :version_unsupported} = History.apply([event()], opts)
    assert History.health(opts).failure == :version_unsupported
    stop_supervised!(@name)
    assert File.read!(path) == bytes
    assert Path.wildcard(path <> ".corrupt-*") == []
  end

  test "V8 wrong repository remains untouched", %{dir: dir, path: path, opts: opts} do
    write(path, %{record() | "repository" => "other/repo"})
    bytes = File.read!(path)
    start(dir)
    assert {:error, :repository_mismatch} = History.apply([event()], opts)
    stop_supervised!(@name)
    assert File.read!(path) == bytes
  end

  test "V9 optional unknown and none round-trip", %{dir: dir, path: path, opts: opts} do
    start(dir)
    History.apply([event(%{title: "x"})], opts)
    r = row(opts)
    for field <- Row.fields() -- [:title, :lifecycle, :clamped], do: assert(Map.fetch!(r, field) == :unknown)
    History.flush(opts)
    assert Jason.decode!(File.read!(path))["rows"] |> hd() |> Map.fetch!("merged_at") == "unknown"
    restart(dir)
    assert row(opts) == r
    History.apply([event(%{closed_at: :none, parent: :none, agent_model: :none}, 1, DateTime.add(@t, 1))], opts)
    restart(dir)
    assert row(opts).closed_at == :none
    assert row(opts).parent == :none
    assert row(opts).agent_model == :none
  end

  test "V10 late mutable facts fill unknown without overwriting", %{dir: dir, opts: opts} do
    start(dir)
    t2 = DateTime.add(@t, 60)
    History.apply([event(%{labels: ["a"]}, 1, t2), event(%{labels: ["b"], title: "x"})], opts)
    assert row(opts).labels == ["a"]
    assert row(opts).title == "x"
    assert row(opts).observed_at == t2
    History.apply([event(%{updated_at: t2, title: "new"}, 2, t2, :webhook)], opts)
    History.apply([event(%{updated_at: @t, title: "old", merged_at: @t, agent_model: "old"}, 2, DateTime.add(t2, 60))], opts)
    assert row(opts, 2).title == "new"
    assert row(opts, 2).merged_at == @t
    History.apply([event(%{updated_at: t2, merged_at: t2, agent_model: "new", dispatched_at: t2}, 2, DateTime.add(t2, 120))], opts)
    History.apply([event(%{updated_at: @t, merged_at: @t, agent_model: "old", dispatched_at: @t}, 2, DateTime.add(t2, 180))], opts)
    assert row(opts, 2).merged_at == t2
    assert row(opts, 2).agent_model == "new"
    assert row(opts, 2).dispatched_at == @t
  end

  test "V11 replay changes nothing and broadcasts once", %{dir: dir, opts: opts} do
    start(dir)
    History.subscribe()
    assert {:ok, %{generation: g, changed: [1]}} = History.apply([event()], opts)
    assert {:ok, %{generation: ^g, changed: []}} = History.apply([event()], opts)
    assert_receive {:build_order_history_changed, %{generation: ^g, changed: [1]}}
    refute_received {:build_order_history_changed, _}
  end

  test "V12 reopen preserves latest merge", %{dir: dir, opts: opts} do
    start(dir)
    History.apply([event(%{lifecycle: %Lifecycle{state: :closed, state_reason: :completed}, closed_at: @t, merged_at: @t})], opts)
    History.apply([event(%{lifecycle: %Lifecycle{state: :open, state_reason: :reopened}, closed_at: :none}, 1, DateTime.add(@t, 1))], opts)
    assert row(opts).lifecycle.state == :open
    assert row(opts).closed_at == :none
    assert row(opts).merged_at == @t
  end

  test "V13 invalid event rejects whole batch", %{dir: dir, opts: opts} do
    start(dir)
    assert {:error, {:invalid_event, 1, :invalid_shape}} = History.apply([event(), event(%{}, 0)], opts)
    assert {:ok, [], _} = History.rows([1], opts)

    for fields <- [%{title: <<255>>}, %{other: 1}, %{labels: nil}, %{sources: []}, %{parent: %{owner: "a", repository: "b", number: 0}}] do
      assert {:error, {:invalid_event, 0, _}} = History.apply([event(fields)], opts)
    end

    assert {:error, :unknown_checkpoint} = History.apply([event()], opts ++ [checkpoint: {:other, %{}}])
    assert {:error, :invalid_checkpoint} = History.apply([event()], opts ++ [checkpoint: {:backfill, %{page: 1}}])
    assert {:ok, [], _} = History.rows([1], opts)
  end

  test "V14 absent store never returns empty success" do
    opts = [server: __MODULE__.Missing]
    assert {:error, %ProviderHealth{failure: :history_not_running}} = History.rows([1], opts)
    assert {:error, %ProviderHealth{failure: :history_not_running}} = History.snapshot(opts)
    assert {:error, %ProviderHealth{failure: :history_not_running}} = History.checkpoint(:backfill, opts)
    assert History.health(opts).failure == :history_not_running
  end

  test "V15 symlink refused at load and write", %{dir: dir, path: path, opts: opts} do
    target = Path.join(dir, "target")
    File.write!(target, "evidence")
    File.ln_s!(target, path)
    start(dir)
    assert History.health(opts).failure == :history_unsafe_path
    assert {:error, :history_unsafe_path} = History.apply([event()], opts)
    stop_supervised!(@name)
    assert File.lstat!(path).type == :symlink
    File.rm!(path)
    start(dir)
    History.apply([event()], opts)
    File.ln_s!(target, path)
    assert {:error, :history_unsafe_path} = History.flush(opts)
    assert History.health(opts).failure == :flush_failed
    assert File.read!(target) == "evidence"
    File.rm!(path)
    send(Process.whereis(@name), :flush)
    :sys.get_state(@name)
    assert History.health(opts).failure == :backfill_pending
    assert File.lstat!(path).type == :regular
  end

  test "V16 measures 1400 and 10000 representative rows", %{dir: dir, path: path, opts: opts} do
    start(dir)

    fields = %{
      labels: for(n <- 1..8, do: "feature:#{n}"),
      blocked_by: for(n <- 1..3, do: %{owner: "acme", repository: "widgets", number: n}),
      label_events: for(n <- 1..10, do: %{label: "feature:#{n}", action: :labeled, at: @t, actor: "engineer"})
    }

    for count <- [1400, 10_000] do
      assert {:ok, _} = History.apply(for(n <- 1..count, do: event(fields, n)), opts)
      {flush_us, :ok} = :timer.tc(fn -> History.flush(opts) end)
      {snapshot_us, {:ok, %{rows: rows}}} = :timer.tc(fn -> History.snapshot(opts) end)
      assert map_size(rows) == count
      bytes = File.stat!(path).size
      assert bytes < 64_000_000
      memory = :ets.info(Module.concat(@name, Mirror), :memory) * :erlang.system_info(:wordsize)
      IO.puts("history_measure rows=#{count} file_bytes=#{bytes} ets_bytes=#{memory} flush_us=#{flush_us} snapshot_us=#{snapshot_us}")
    end
  end

  test "V17 file is owner-only", %{dir: dir, path: path, opts: opts} do
    start(dir)
    History.apply([event()], opts)
    History.flush(opts)
    assert (File.stat!(path).mode &&& 0o777) == 0o600
  end

  test "V18 batch broadcast carries numbers and generation", %{dir: dir, opts: opts} do
    start(dir)
    History.subscribe()
    before = History.health(opts).generation
    assert {:ok, %{generation: g, changed: [3, 5]}} = History.apply([event(%{}, 5), event(%{}, 3)], opts)
    assert g == before + 1
    assert_receive {:build_order_history_changed, %{generation: ^g, changed: [3, 5], health: %ProviderHealth{observed_at: @t}}}
    History.apply([], opts ++ [checkpoint: {:closed_since, %{"at" => "today"}}])
    assert History.health(opts).generation == g
    refute_received {:build_order_history_changed, _}
    restart(dir)
    assert {:ok, %{"at" => "today"}} = History.checkpoint(:closed_since, opts)
  end

  test "V19 unavailable directory does not crash boot", %{dir: dir, opts: opts} do
    file = Path.join(dir, "file")
    File.write!(file, "x")
    start(Path.join(file, "child"))
    assert History.health(opts).failure == :state_dir_unavailable
    assert {:error, :state_dir_unavailable} = History.apply([event()], opts)
  end

  test "V20 signals use earliest and latest regardless of order", %{dir: dir, opts: opts} do
    start(dir)
    later = DateTime.add(@t, 60)
    a = %{in_progress_at: later, merged_at: later, pr_number: 10, last_closed_at: later}
    b = %{in_progress_at: @t, merged_at: @t, pr_number: 9, last_closed_at: @t}
    History.apply([event(a), event(b), event(b, 2), event(a, 2)], opts)
    assert row(opts).in_progress_at == @t
    assert row(opts).merged_at == later
    assert row(opts).pr_number == 10
    assert row(opts).last_closed_at == later
    assert Map.drop(Map.from_struct(row(opts)), [:number]) == Map.drop(Map.from_struct(row(opts, 2)), [:number])
  end

  test "V21 corrupt store allows rebuild while hard failures refuse", %{dir: dir, path: path, opts: opts} do
    File.write!(path, "bad")
    start(dir)
    assert History.writable?(History.health(opts))
    assert {:ok, %{changed: [1]}} = History.apply([event()], opts)

    for failure <- [:version_unsupported, :repository_mismatch, :state_dir_unavailable, :history_unsafe_path, :not_applicable, :history_not_running] do
      refute History.writable?(ProviderHealth.new(1, :unavailable, false, failure: failure))
    end
  end

  test "V22 memory repository creates no directory", %{dir: dir, opts: opts} do
    nonexistent = Path.join(dir, "not-created")
    start(nonexistent, repository: "memory")
    assert History.health(opts).failure == :not_applicable
    assert {:error, :not_applicable} = History.apply([event()], opts)
    refute File.exists?(nonexistent)
  end

  test "V23 lifecycle round-trips exactly and rejects bogus reasons", %{dir: dir, path: path, opts: opts} do
    start(dir)

    lifecycles = [
      %Lifecycle{state: :open, state_reason: :none},
      %Lifecycle{state: :open, state_reason: :reopened},
      %Lifecycle{state: :closed, state_reason: :not_planned},
      %Lifecycle{state: :closed, state_reason: :unknown}
    ]

    History.apply(for({l, n} <- Enum.with_index(lifecycles, 1), do: event(%{lifecycle: l}, n)), opts)
    restart(dir)
    assert Enum.map(1..4, &row(opts, &1).lifecycle) == lifecycles
    stop_supervised!(@name)
    record = Jason.decode!(File.read!(path))
    write(path, %{record | "rows" => [Map.put(hd(record["rows"]), "state_reason", "bogus")]})
    start(dir)
    assert History.health(opts).failure == :history_corrupt
  end

  test "V24 cross-repository refs and timeline unions round-trip", %{dir: dir, opts: opts} do
    start(dir)
    ref = %{owner: "other", repository: "lib", number: 4}
    label = %{label: "feature:a", action: :labeled, at: @t, actor: :unknown}
    added = %{ref: ref, at: @t}
    fields = %{blocked_by: [ref], parent: ref, label_events: [label], sub_issues_added: [added]}
    History.apply([event(fields), event(fields, 1, @t, :webhook)], opts)
    restart(dir)
    assert row(opts).blocked_by == [ref]
    assert row(opts).parent == ref
    assert row(opts).label_events == [label]
    assert row(opts).sub_issues_added == [added]
    assert row(opts).sources == [:backfill, :webhook]
    earlier = %{label | label: "feature:earlier", at: DateTime.add(@t, -60)}
    earlier_added = %{added | at: DateTime.add(@t, -60)}
    History.apply([event(%{label_events: [earlier], sub_issues_added: [earlier_added]}, 1, DateTime.add(@t, 1))], opts)
    assert row(opts).label_events == [earlier, label]
    assert row(opts).sub_issues_added == [earlier_added, added]
    assert {:error, {:invalid_event, 0, _}} = History.apply([event(%{blocked_by: [%{ref | number: 0}]})], opts)
  end

  test "V25 derived facts require derive source", %{dir: dir, opts: opts} do
    start(dir)
    assert {:error, {:invalid_event, 0, {:invalid_field, :start}}} = History.apply([event(%{start: @t}, 1, @t, :webhook)], opts)
    assert {:ok, _} = History.apply([event(%{start: @t, start_source: :label, end: :none, clamped: true}, 1, @t, :derive)], opts)
    assert row(opts).start == @t
    assert row(opts).clamped
  end

  test "reserved literal strings and unknown lifecycle remain lossless", %{dir: dir, opts: opts} do
    pid = start(dir)

    fields = %{
      title: "unknown",
      node_id: "none",
      agent_model: "none",
      agent_effort: "unknown",
      parent_version: "none",
      parent: %{owner: "unknown", repository: "none", number: 1},
      label_events: [%{label: "unknown", action: :labeled, at: @t, actor: "none"}],
      labels: ["unknown", "none"]
    }

    History.apply([event(fields)], opts)
    assert {:ok, [before], _} = History.rows([1], server: pid)
    restart(dir)
    assert row(opts) == before
    assert {:error, {:invalid_event, 0, {:invalid_field, :lifecycle}}} = History.apply([event(%{lifecycle: :unknown})], opts)
    lifecycle = %Lifecycle{state: :closed, state_reason: :completed}
    History.apply([event(%{lifecycle: lifecycle}, 1, DateTime.add(@t, -1))], opts)
    assert row(opts).lifecycle == lifecycle
    History.apply([event(%{updated_at: @t}, 2)], opts)
    History.apply([event(%{updated_at: DateTime.add(@t, -1), lifecycle: lifecycle}, 2, DateTime.add(@t, 60))], opts)
    assert row(opts, 2).lifecycle == lifecycle
  end

  test "failed flush during rebuilding still accepts recovery writes", %{dir: dir, path: path, opts: opts} do
    File.write!(path, "bad")
    start(dir)
    target = Path.join(dir, "target")
    File.write!(target, "unchanged")
    File.ln_s!(target, path)
    assert {:error, :history_unsafe_path} = History.flush(opts)
    assert History.writable?(History.health(opts))
    assert {:ok, %{changed: [1]}} = History.apply([event()], opts)
    File.rm!(path)
    assert :ok = History.flush(opts)
    assert History.health(opts).failure == :history_rebuilding
    assert :ok = History.mark_complete(opts)
    assert row(opts).number == 1
    assert File.read!(target) == "unchanged"
  end

  test "unreadable regular files remain untouched", %{dir: dir, path: path, opts: opts} do
    write(path, record())
    File.chmod!(path, 0o000)
    start(dir)
    assert History.health(opts).failure == :state_dir_unavailable
    assert {:error, :state_dir_unavailable} = History.apply([event()], opts)
    stop_supervised!(@name)
    File.chmod!(path, 0o600)
    assert Jason.decode!(File.read!(path)) == record()
    assert Path.wildcard(path <> ".corrupt-*") == []
  end

  test "V26 non-parent exit leaves store alive", %{dir: dir, opts: opts} do
    pid = start(dir)
    History.apply([event()], opts)
    send(pid, {:EXIT, self(), :boom})
    assert {:ok, %{rows: rows}} = History.snapshot(opts)
    assert rows[1].number == 1
    assert Process.alive?(pid)
  end
end
