defmodule Aiur.Experiments.Auto.SpecBuilder do
  @moduledoc false
  alias Aiur.Experiments.Auto.Line

  @spec build(Line.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def build(line, config, catalog) do
    with :ok <- validate(line), {:ok, metrics} <- metrics(packs(line, config, catalog), catalog) do
      type = if line.source == :feature, do: "epic_merge", else: "release"
      at = DateTime.to_iso8601(line.at)
      before = before_window(line, config)
      evidence = Map.merge(line.evidence, %{source: to_string(line.source)})
      evidence = if before.end != at, do: Map.put(evidence, :excluded, %{start: before.end, end: at}), else: evidence

      {:ok,
       %{
         key: line.key,
         title: "#{line.source}: #{ref(line)}",
         status: if(line.source == :feature and line.evidence[:armed] == true, do: "draft", else: "active"),
         owner: %{kind: "agent", id: "auto"},
         origin: %{kind: type, ref: ref(line)},
         design: %{kind: "before_after", change: %{type: type, ref: ref(line), time: at, evidence: evidence}, assign_by: "start"},
         metrics: metrics,
         windows: %{before: before, after: window(line.at, DateTime.add(line.at, config.after_days * 86_400))}
       }}
    end
  end

  defp packs(%Line{source: :repo_release}, config, catalog) do
    auto = for {id, pack} <- catalog.packs, is_map(pack) and pack["auto"] == true, do: id
    Enum.uniq(config.metric_packs ++ auto)
  end

  defp packs(_line, config, _catalog), do: config.metric_packs

  @spec ref(Line.t()) :: String.t()
  def ref(line), do: String.replace_prefix(line.key, prefix(line.source), "")

  defp validate(%Line{source: source, key: key, at: %DateTime{} = at, evidence: evidence, before_floor: floor, before_window: before})
       when source in [:aiur_version, :repo_release, :feature] and is_binary(key) and is_map(evidence) do
    if String.starts_with?(key, prefix(source)) and key != prefix(source) and (is_nil(floor) or is_struct(floor, DateTime)) and valid_before?(before, at), do: :ok, else: {:error, :invalid_line}
  end

  defp validate(_line), do: {:error, :invalid_line}
  defp valid_before?(nil, _at), do: true
  defp valid_before?({%DateTime{} = from, %DateTime{} = until}, at), do: DateTime.compare(from, until) == :lt and DateTime.compare(until, at) != :gt
  defp valid_before?(_invalid, _at), do: false

  defp prefix(:aiur_version), do: "auto:version:"
  defp prefix(:repo_release), do: "auto:release:"
  defp prefix(:feature), do: "auto:feature:"

  defp before_window(%Line{before_window: {from, until}}, _config), do: window(from, until)

  defp before_window(line, config) do
    from = DateTime.add(line.at, -config.before_days * 86_400)
    from = if line.before_floor && DateTime.compare(line.before_floor, from) == :gt, do: line.before_floor, else: from
    window(from, line.at)
  end

  defp window(from, until), do: %{start: DateTime.to_iso8601(from), end: DateTime.to_iso8601(until)}

  defp metrics(packs, catalog) do
    packs = Enum.map(packs, fn pack -> if pack == "delivery", do: "delivery-speed", else: pack end)
    missing = Enum.reject(packs, &Map.has_key?(catalog.packs, &1))

    if missing == [] do
      metrics = catalog.metrics |> Enum.filter(fn {_ref, metric} -> metric.pack in packs end) |> Enum.sort_by(&elem(&1, 0))
      {:ok, metrics |> Enum.with_index() |> Enum.map(fn {{ref, metric}, index} -> %{ref: ref, direction: metric.default_direction, primary: index == 0} end)}
    else
      {:error, {:metric_packs_unavailable, missing}}
    end
  end
end
