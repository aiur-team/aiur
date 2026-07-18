defmodule Aiur.UsageAggregate.StoreTest do
  use ExUnit.Case, async: false

  alias Aiur.UsageAggregate.Store
  alias Aiur.UsageLedger
  import Aiur.TestSupport.UsageAggregate, only: [envelope: 1]

  @run "run-1115"

  setup do
    ledger_root = tmp("ledger")
    agg_root = tmp("aggregate")
    ledger_name = unique(:ledger)
    agg_name = unique(:aggregate)

    {:ok, ledger} = UsageLedger.Store.start_link(name: ledger_name, state_dir: ledger_root, filesystem_sync_fun: fn -> :ok end)

    on_exit(fn ->
      File.rm_rf(ledger_root)
      File.rm_rf(agg_root)
    end)

    %{ledger: ledger, ledger_name: ledger_name, agg_root: agg_root, agg_name: agg_name}
  end

  test "catches up from the persisted ledger on boot and serves a bounded scope", context do
    append(context.ledger_name, envelope(%{tokens: token(10)}))
    append(context.ledger_name, envelope(%{tokens: token(5)}))

    {:ok, agg} = start_aggregate(context)

    summary = Store.query(%{runs: [@run]}, context.agg_name)
    assert summary.totals.tokens == %{input: 15}
    assert summary.reconciliation.reconciled?
    assert Store.snapshot(context.agg_name).freshness.status == :fresh
    assert Store.generation(context.agg_name) == 2
    GenServer.stop(agg)
  end

  test "folds a live delta published after subscription and stays fresh", context do
    {:ok, agg} = start_aggregate(context)
    assert Store.snapshot(context.agg_name).freshness.status == :empty

    append(context.ledger_name, envelope(%{tokens: token(7)}))

    # The ledger sends the refresh before its append call returns, so the fold
    # is already queued ahead of this synchronous query — no sleep required.
    summary = Store.query(%{runs: [@run]}, context.agg_name)
    assert summary.totals.tokens == %{input: 7}
    assert Store.snapshot(context.agg_name).freshness.status == :fresh
    GenServer.stop(agg)
  end

  test "recovers from its checkpoint after restart and folds only new positions", context do
    append(context.ledger_name, envelope(%{tokens: token(10)}))
    append(context.ledger_name, envelope(%{tokens: token(5)}))
    {:ok, agg} = start_aggregate(context)
    assert Store.generation(context.agg_name) == 2
    GenServer.stop(agg)

    append(context.ledger_name, envelope(%{tokens: token(7)}))
    {:ok, restarted} = start_aggregate(context)

    summary = Store.query(%{runs: [@run]}, context.agg_name)
    assert summary.totals.tokens == %{input: 22}
    assert Store.snapshot(context.agg_name).source_position == 3
    # Two folded before restart plus one after — never re-folded.
    assert Store.generation(context.agg_name) == 3
    GenServer.stop(restarted)
  end

  test "rebuilds from the retained ledger authority when the checkpoint is corrupt", context do
    append(context.ledger_name, envelope(%{tokens: token(10)}))
    append(context.ledger_name, envelope(%{tokens: token(5)}))
    {:ok, agg} = start_aggregate(context)
    GenServer.stop(agg)

    File.write!(Path.join(context.agg_root, "checkpoint.json"), "corrupt not json")
    {:ok, rebuilt} = start_aggregate(context)

    summary = Store.query(%{runs: [@run]}, context.agg_name)
    assert summary.totals.tokens == %{input: 15}
    snapshot = Store.snapshot(context.agg_name)
    assert snapshot.recovery == :rebuilt_corrupt
    assert snapshot.health == :healthy
    assert File.ls!(Path.join(context.agg_root, "quarantine")) != []
    GenServer.stop(rebuilt)
  end

  test "preserves the last-known-good projection when a checkpoint write fails", context do
    {:ok, agg} =
      start_aggregate(context, checkpoint_write_fun: fn _path, _projection -> {:error, :eio} end)

    append(context.ledger_name, envelope(%{tokens: token(10)}))

    summary = Store.query(%{runs: [@run]}, context.agg_name)
    assert summary.totals.tokens == %{input: 10}
    assert Store.health(context.agg_name) == {:degraded, :checkpoint_write_failed}
    GenServer.stop(agg)
  end

  test "an empty ledger is a distinct healthy empty state", context do
    {:ok, agg} = start_aggregate(context)

    snapshot = Store.snapshot(context.agg_name)
    assert snapshot.freshness.status == :empty
    assert snapshot.health == :healthy
    assert snapshot.generation == 0
    assert snapshot.cell_count == 0
    GenServer.stop(agg)
  end

  test "an unreachable source is degraded and stale, not empty or corrupt", context do
    {:ok, agg} =
      start_aggregate(context,
        ledger_scan_fun: fn _opts -> {:error, :ledger_unavailable} end,
        ledger_generation_fun: fn -> raise "unavailable" end
      )

    assert Store.health(context.agg_name) == {:degraded, :source_unavailable}
    assert Store.snapshot(context.agg_name).freshness.status == :stale
    GenServer.stop(agg)
  end

  test "stays unavailable when its owner-only state directory cannot be prepared", context do
    blocked = Path.join(context.agg_root, "blocked")
    File.mkdir_p!(context.agg_root)
    File.write!(blocked, "not a directory")

    {:ok, agg} = start_aggregate(%{context | agg_root: blocked})

    assert match?({:unavailable, _reason}, Store.health(context.agg_name))
    assert Store.snapshot(context.agg_name).freshness.status == :unavailable
    GenServer.stop(agg)
  end

  test "publishes one change payload per advancing refresh and never inflates on duplicates", context do
    parent = self()

    {:ok, agg} =
      start_aggregate(context, publish_fun: fn payload -> send(parent, {:published, payload}) end)

    assert_receive {:published, %{generation: 0}}

    append(context.ledger_name, envelope(%{tokens: token(10)}))
    _ = Store.snapshot(context.agg_name)
    assert_receive {:published, %{generation: 1, source_position: 1}}

    # Duplicate delivery of an already-applied position is a no-op: no new
    # publication and no inflated total.
    send(agg, {:usage_ledger_delta, %{position: 1, generation: 1, delta: %{}}})
    send(agg, {:usage_ledger_delta, %{position: 1, generation: 1, delta: %{}}})
    assert Store.query(%{runs: [@run]}, context.agg_name).totals.tokens == %{input: 10}
    refute_received {:published, _payload}
    GenServer.stop(agg)
  end

  defp start_aggregate(context, opts \\ []) do
    ledger_name = context.ledger_name

    defaults = [
      name: context.agg_name,
      state_dir: context.agg_root,
      filesystem_sync_fun: fn -> :ok end,
      ledger_scan_fun: fn scan_opts -> GenServer.call(ledger_name, {:scan, scan_opts}) end,
      ledger_subscribe_fun: fn pid -> GenServer.call(ledger_name, {:subscribe, pid}) end,
      ledger_generation_fun: fn -> GenServer.call(ledger_name, :generation) end,
      ledger_coverage_fun: fn -> GenServer.call(ledger_name, :coverage) end
    ]

    Store.start_link(Keyword.merge(defaults, opts))
  end

  defp append(ledger_name, envelope), do: UsageLedger.Store.append(ledger_name, envelope)

  defp token(input) do
    %{input: input, cached_input: nil, cache_creation_input: nil, output: nil, reasoning_output: nil, provider_reported_total: nil}
  end

  defp tmp(kind), do: Path.join(System.tmp_dir!(), "aiur-usage-#{kind}-#{System.unique_integer([:positive])}")
  defp unique(kind), do: String.to_atom("usage_#{kind}_#{System.unique_integer([:positive])}")
end
