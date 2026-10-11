defmodule Aiur.Experiments.Sources.NdjsonTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.{Metric, Sources.Ndjson}

  @window %{start: ~U[2026-01-01 10:00:00Z], end: ~U[2026-01-01 13:00:00Z]}

  setup do
    root = Path.join(System.tmp_dir!(), "metric-ndjson-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "malformed lines are counted, outside-window samples excluded", %{root: root} do
    body =
      Enum.map_join([{"early", "2026-01-01T09:00:00Z"}, {"inside", "2026-01-01T11:00:00Z"}, {"late", "2026-01-01T13:00:00Z"}], "\n", fn {unit, at} ->
        Jason.encode!(%{unit_id: unit, value: 3, at: at})
      end)

    File.write!(Path.join(root, "observations.ndjson"), body <> "\ninvalid\n")
    metric = %Metric{source: %{"path" => "observations.ndjson"}, requires: []}
    result = Ndjson.observations(metric, "app/value", @window, %{repo_path: root})
    assert result.coverage == %{state: :captured, malformed_lines: 1}
    assert [%{unit_id: "inside", value: 3}] = result.observations
  end

  test "traversal and symlinks outside the base checkout are unavailable", %{root: root} do
    metric = %Metric{source: %{"path" => "../secret.ndjson"}}
    assert %{coverage: %{state: :unavailable, reason: :outside_root}, observations: []} = Ndjson.observations(metric, "app/value", @window, %{repo_path: root})
    File.ln_s!(Path.join(Path.dirname(root), "secret.ndjson"), Path.join(root, "link.ndjson"))
    metric = %{metric | source: %{"path" => "link.ndjson"}}
    assert %{coverage: %{state: :unavailable, reason: :outside_root}, observations: []} = Ndjson.observations(metric, "app/value", @window, %{repo_path: root})
  end

  test "state paths are contained in the repository state node", %{root: root} do
    state = Path.join(root, "state")
    File.mkdir_p!(state)
    File.write!(Path.join(state, "stats.ndjson"), Jason.encode!(%{unit_id: "sample", value: 8, at: "2026-01-01T10:00:00Z"}))
    metric = %Metric{source: %{"path" => "state:stats.ndjson"}}
    assert %{observations: [%{value: 8}]} = Ndjson.observations(metric, "app/value", @window, %{repo_path: root, state_path: state})
  end
end
