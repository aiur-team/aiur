defmodule Aiur.BuildOrder.IndexOpenPrTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.StartTrigger.ProgressStore
  alias AiurWeb.Build.Payload

  setup do
    :ok = Supervisor.terminate_child(Aiur.Supervisor, ProgressStore)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, ProgressStore) end)
    start_supervised!({ProgressStore, seed: fn -> %{passed_heads: %{}} end})
    :ok
  end

  test "open PR evidence reaches now rows and the desktop ticket payload" do
    ProgressStore.record("77", %{pr_number: 88, stage: :pr_opened})
    :sys.get_state(ProgressStore)
    assert {:ok, index} = assemble(put_in(parts(), [:now, :rows], %{"77" => Map.put(now_row(77), :agent, %{state: "ci_wait", model: "codex", name: "Codex", effort: "high"})}))
    assert index.all["77"].pr == %{num: 88, state: "open", ci: "pr_opened"}
    payload = Payload.ticket(index.all["77"], "epoch", 1)
    assert payload["row"]["pr"] == %{"num" => 88, "state" => "open", "ci" => "pr_opened"}
    assert :ok = Payload.validate(payload)
  end

  test "future regression guard: missing, closed and historical evidence never becomes an open PR" do
    ProgressStore.record("78", %{pr_number: 88, closed_unmerged?: true})
    ProgressStore.record("79", %{pr_number: 89, stage: :pr_ci_green})
    :sys.get_state(ProgressStore)
    p = parts([row(79), row(80, %{pr_number: 90, merged_at: DateTime.utc_now()})])
    p = put_in(p, [:now, :rows], Map.new([77, 78], &{to_string(&1), now_row(&1)}))
    assert {:ok, index} = assemble(p)
    assert index.all["77"].pr == nil
    assert index.all["78"].pr == nil
    assert index.all["79"].pr == nil
    assert index.all["80"].pr == %{num: 90, state: "merged"}
  end
end
