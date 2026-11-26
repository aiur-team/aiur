defmodule Aiur.Experiments.Packs.DeliverySpeedRegistrationTest do
  use Aiur.TestSupport

  alias Aiur.Experiments
  alias Aiur.Experiments.Packs.DeliverySpeed.{Periods, Tickets}
  alias Aiur.Experiments.Store

  setup do
    path = Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, File.read!(path) <> "\nexperiments:\n  pack_dirs: []\n")
    :ok = Aiur.WorkflowStore.force_reload()
    start_supervised!(Store)
    :ok
  end

  test "configured built-in delivery-speed pack accepts creation and suggests an unknown ref" do
    attrs = %{
      title: "Delivery change",
      hypothesis: "Faster delivery",
      design: %{kind: "before_after", change: %{type: "manual", ref: "test", time: "2026-10-01T00:00:00Z"}},
      metrics: [%{ref: "delivery-speed/start_to_merge", direction: "decrease"}]
    }

    assert {:ok, spec} = Experiments.create(attrs)
    assert spec.metrics == [%{"ref" => "delivery-speed/start_to_merge", "direction" => "decrease", "primary" => true}]

    bad = Map.put(attrs, :metrics, [%{ref: "delivery-speed/start_to_merg"}])
    assert {:error, [%{path: "metrics.0.ref", message: message}]} = Experiments.create(bad)
    assert message =~ "delivery-speed/start_to_merge"
  end

  test "unsupported captured metric ids omit qualifying ticket and active period observations" do
    window = %{start: ~U[2026-10-09 10:00:00Z], end: ~U[2026-10-09 11:00:00Z]}

    data = %{
      tickets: %{"101" => %{ticket: "101", at: window.start, events: []}},
      capacity: [%{start: window.start, end: window.end, running: 1, cap: 2}]
    }

    assert Tickets.observations("future_ticket_metric", data, window) == {[], 1}
    assert Periods.observations("future_period_metric", data, window) == {[], 1}
  end
end
