defmodule AiurWeb.Experiments.ViewModelTest do
  use ExUnit.Case, async: true

  alias AiurWeb.Experiments.ViewModel

  test "line metadata shows the change and windows without inventing evidence from snapshot filenames" do
    spec = fixture("valid_line")
    model = ViewModel.detail(%{spec: spec, phase: :collecting, annotations: [], snapshots: ["baseline.json"]})

    assert model.kind_label == "Before/after"
    assert model.design_summary == "v0.0.9 · 2026-10-09T00:00:00Z"
    assert model.hypothesis == "Delivery gets faster"
    assert model.min_samples == 15

    assert model.window_labels == [
             %{label: "Before", text: "2026-09-25T00:00:00Z → 2026-10-09T00:00:00Z"},
             %{label: "After", text: "2026-10-09T00:00:00Z → Open"}
           ]

    assert model.metric_specs == [%{"ref" => "delivery-speed/start_to_merge", "direction" => "decrease", "primary" => true}]
    assert model.metrics == []
    assert model.labels == []
    assert model.evidence_state == :pending
    assert model.frozen_baseline == :unknown
  end

  test "frozen baseline uses the latest before revision and exposes its provenance" do
    baseline = %{"window_name" => "before", "revision" => 2, "computed_at" => "2026-10-10T00:00:00Z", "aiur_version" => "0.0.9", "sha256" => "frozen-hash"}
    snapshots = [%{"window_name" => "after", "revision" => 9}, Map.put(baseline, "revision", 1), baseline]
    model = ViewModel.detail(%{spec: fixture("valid_line"), snapshots: snapshots, pack_changed_since_freeze: true})
    assert model.frozen_baseline == %{revision: 2, computed_at: "2026-10-10T00:00:00Z", aiur_version: "0.0.9", sha256: "frozen-hash"}
    assert model.pack_changed_since_freeze?
    assert ViewModel.detail(%{spec: fixture("valid_ab"), snapshots: snapshots}).frozen_baseline == :unknown
  end

  test "cohort chip reflects the actual design count" do
    spec = fixture("valid_ab")
    assert ViewModel.detail(%{spec: spec}).kind_label == "A/B"
    assert ViewModel.detail(%{spec: spec}).design_summary == "Control · Test"

    for {count, label} <- [{3, "A/B/C"}, {4, "A/B/C/D"}, {5, "5 cohorts"}] do
      spec = put_in(spec, ["design", "cohorts"], List.duplicate(%{"label" => "Cohort"}, count))
      assert ViewModel.detail(%{spec: spec}).kind_label == label
    end
  end

  test "custom metric specifications retain refs without presuming pack labels or result counts" do
    spec = put_in(fixture("valid_line"), ["metrics"], [%{"ref" => "custom/checkout_latency_ms", "direction" => "decrease", "primary" => true}])
    model = ViewModel.detail(%{spec: spec})
    assert hd(model.metric_specs)["ref"] == "custom/checkout_latency_ms"
    assert model.metrics == []
    refute Map.has_key?(model, :sample_count)
  end

  test "active experiments lead, newest timestamps use offsets, and tied timestamps use id" do
    items = [
      item("closed", "concluded", "2026-10-11T00:00:00Z"),
      item("b", "active", "2026-10-10T00:00:00Z"),
      item("a", "collecting", "2026-10-10T00:00:00Z"),
      item("offset", "active", "2026-10-09T21:00:00-04:00"),
      item("old", "abandoned", "2026-10-01T00:00:00Z")
    ]

    assert Enum.map(ViewModel.order(items), & &1.id) == ["offset", "a", "b", "closed", "old"]
  end

  test "unknown newer schema preserves unknown design and missing metadata" do
    model = ViewModel.detail(%{spec: %{"schema_version" => 2, "design" => "future"}, read_only?: true})
    assert model.kind_label == "Unknown design"
    assert model.design_summary == "Unknown design"
    assert model.status == "unknown"
    assert model.window_labels == []
    assert model.frozen_baseline == :unknown
    assert model.read_only?
  end

  test "generated metadata copy contains no verdict words" do
    for name <- ["valid_line", "valid_ab"] do
      model = ViewModel.detail(%{spec: fixture(name)})
      copy = Enum.join([model.kind_label, model.status, model.design_summary, Atom.to_string(model.evidence_state)], " ")
      refute copy =~ ~r/win|better|worse|regress|improv/i
    end
  end

  defp item(id, status, created_at), do: %{id: id, status: status, created_at: created_at}

  defp fixture(name) do
    Path.expand("../../aiur/experiments/fixtures/#{name}.json", __DIR__) |> File.read!() |> Jason.decode!() |> Map.fetch!("spec")
  end
end
