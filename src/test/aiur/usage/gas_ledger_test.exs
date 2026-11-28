defmodule Aiur.Usage.GasLedgerTest do
  use ExUnit.Case, async: false

  alias Aiur.Usage.GasLedger

  test "records idempotent paid API spend durably and isolates user totals" do
    root = Aiur.TestSupport.tmp_root!("usage-gas-ledger")
    name = :usage_gas_ledger_test

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, ledger} = GasLedger.start_link(name: name, state_dir: root)

    attrs = %{
      id: "fal-charge-01",
      user_id: "host-user-7",
      api: "fal",
      amount_usd: "1.25",
      occurred_at: "2026-11-27T12:00:00Z",
      basis: "actual",
      ticket: "8156",
      conversation_id: "conv-2"
    }

    assert {:ok, first} = GasLedger.record(attrs, ledger)
    assert {:duplicate, ^first} = GasLedger.record(attrs, ledger)
    assert %{spent_usd: total, records: [record], record_count: 1} = GasLedger.snapshot("host-user-7", ledger)
    assert Decimal.equal?(total, Decimal.new("1.25"))
    assert record.api == "fal"
    assert GasLedger.snapshot("other-user", ledger).spent_usd == Decimal.new(0)

    GenServer.stop(ledger)
    {:ok, recovered} = GasLedger.start_link(name: name, state_dir: root)
    assert GasLedger.snapshot("host-user-7", recovered).spent_usd == Decimal.new("1.25")
    GenServer.stop(recovered)
  end

  test "rejects a changed amount under an already used idempotency key" do
    root = Aiur.TestSupport.tmp_root!("usage-gas-conflict")
    name = :usage_gas_conflict_test
    {:ok, ledger} = GasLedger.start_link(name: name, state_dir: root)

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(root)
    end)

    attrs = %{id: "charge-2", user_id: "u-2", api: "fal", amount_usd: "0.50", occurred_at: "2026-11-27T12:00:00Z"}
    assert {:ok, _record} = GasLedger.record(attrs, ledger)
    assert {:error, :idempotency_conflict} = GasLedger.record(%{attrs | amount_usd: "0.75"}, ledger)
  end
end
