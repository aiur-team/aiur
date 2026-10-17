defmodule Aiur.Experiments.ChartGroups do
  @moduledoc false
  alias Aiur.Experiments.{Arms, Snapshot}

  @spec build(map(), String.t(), map(), [String.t()], String.t() | nil) :: [map()]
  def build(detail, ref, result, order, stratum) do
    snapshots = detail.snapshots |> Enum.group_by(& &1["window_name"]) |> Enum.map(fn {name, rows} -> {name, Enum.max_by(rows, & &1["revision"])} end)
    windows = Enum.map(snapshots, fn {name, snapshot} -> {name, %{source: :frozen, metrics: snapshot["metrics"] || %{}}} end)
    arms = Arms.assign(detail.spec, windows)["arms"]
    order = if order == [], do: group_order(detail.spec), else: order
    Enum.map(order, &group(&1, get_in(result, ["groups", &1]) || %{}, get_in(arms, [&1, "metrics", ref, "observations"]) || [], detail.spec, stratum))
  end

  defp group(name, summary, rows, spec, stratum) do
    points = rows |> Enum.reject(& &1["censored"]) |> Enum.filter(&selected?(&1, spec["stratify_by"], stratum)) |> Enum.sort_by(&{&1["at"], &1["unit_id"]})

    summary = descriptive(summary, points)

    %{
      name: name,
      label: label(spec, name),
      n: summary["n"] || length(points),
      median: summary["median"],
      q1: summary["q1"],
      q3: summary["q3"],
      whiskers: whiskers(summary, points),
      points: Enum.take(points, 500)
    }
  end

  defp descriptive(summary, points) when map_size(summary) == 0 do
    values = Snapshot.summary(points)
    Map.merge(values, %{"q1" => values["p25"], "q3" => values["p75"]})
  end

  defp descriptive(summary, _points), do: summary

  defp selected?(_row, _fields, nil), do: true

  defp selected?(row, [field], selected) do
    value =
      Enum.reduce(String.split(field, "."), row["attrs"] || %{}, fn
        key, attrs when is_map(attrs) -> attrs[key]
        _key, _value -> nil
      end)

    stratum_label(value) == selected
  end

  defp selected?(_row, _fields, _selected), do: false

  defp stratum_label(nil), do: "unknown"
  defp stratum_label(true), do: "True"
  defp stratum_label(false), do: "False"
  defp stratum_label(value) when is_list(value), do: value |> Enum.sort_by(&Jason.encode!/1) |> Jason.encode!()
  defp stratum_label(value), do: to_string(value)
  defp group_order(%{"design" => %{"kind" => "ab", "cohorts" => cohorts}}), do: Enum.map(cohorts, & &1["id"])
  defp group_order(_spec), do: ~w(before after)

  defp label(%{"design" => %{"cohorts" => cohorts}}, name), do: Enum.find_value(cohorts, name, fn cohort -> if cohort["id"] == name, do: cohort["label"] end)
  defp label(_spec, name), do: String.capitalize(name)

  defp whiskers(%{"q1" => q1, "q3" => q3}, points) when is_number(q1) and is_number(q3) do
    values = points |> Enum.map(& &1["value"]) |> Enum.filter(&(&1 >= q1 - 1.5 * (q3 - q1) and &1 <= q3 + 1.5 * (q3 - q1)))
    if values == [], do: nil, else: {Enum.min(values), Enum.max(values)}
  end

  defp whiskers(_summary, _points), do: nil
end
