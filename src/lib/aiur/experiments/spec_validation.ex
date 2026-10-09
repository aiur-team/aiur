defmodule Aiur.Experiments.SpecValidation do
  @moduledoc false
  alias Aiur.Experiments.{Paths, Predicate, Spec, SpecFields}
  import SpecFields

  @spec validate(map()) :: [map()]
  def validate(map) do
    object(map, Map.keys(Spec.to_map(%Spec{})), "") ++
      field(map, "schema_version", &(&1 == 1), "must equal 1") ++
      field(map, "id", &(is_nil(&1) or Paths.valid_id?(&1)), "invalid experiment id") ++
      field(map, "key", &(is_nil(&1) or text?(&1)), "must be a nonempty string or null") ++
      field(map, "title", &text?/1, "must be a nonempty string") ++
      Enum.flat_map(~w(hypothesis notes), &field(map, &1, fn value -> is_binary(value) end, "must be a string")) ++
      field(map, "status", &(&1 in ~w(draft active concluded abandoned)), "unknown status") ++
      field(map, "min_samples", &positive?/1, "must be a positive integer") ++
      Enum.flat_map(~w(alpha power_target), &field(map, &1, fn value -> probability?(value) end, "must be between 0 and 1")) ++
      Enum.flat_map(~w(created_at updated_at), &field(map, &1, fn value -> timestamp?(value) end, "must be an ISO-8601 timestamp with an offset")) ++
      field(map, "registered_at", &optional_timestamp?/1, "must be a timestamp or null") ++
      owner(map["owner"]) ++
      origin(map["origin"]) ++
      design(map["design"]) ++
      metrics(map["metrics"]) ++
      windows(map["windows"], map["design"]) ++
      Predicate.validate(map["filters"], "filters") ++
      field(map, "stratify_by", &unique_attributes?/1, "must contain unique cohort attributes") ++
      field(map, "tags", &unique_strings?/1, "must contain unique strings")
  end

  defp owner(owner) do
    object(owner, ~w(kind id), "owner") ++ field(owner, "kind", &(&1 in ~w(human agent)), "unknown owner kind", "owner") ++ field(owner, "id", &text?/1, "must be a nonempty string", "owner")
  end

  defp origin(origin) do
    object(origin, ~w(kind ref), "origin") ++
      field(origin, "kind", &(&1 in ~w(manual release epic_merge analyst)), "unknown origin kind", "origin") ++
      field(origin, "ref", &(is_nil(&1) or is_binary(&1)), "must be a string or null", "origin")
  end

  defp design(%{"kind" => "before_after"} = design) do
    change = design["change"]

    object(design, ~w(kind change assign_by), "design") ++
      field(design, "assign_by", &(&1 in ~w(start finish)), "must be start or finish", "design") ++
      object(change, ~w(type ref time evidence), "design.change", ~w(type ref time)) ++
      field(change, "type", &(&1 in ~w(release tag commit epic_merge merge config manual)), "unknown change type", "design.change") ++
      field(change, "ref", &text?/1, "must be a nonempty string", "design.change") ++
      field(change, "time", &timestamp?/1, "must be an ISO-8601 timestamp with an offset", "design.change")
  end

  defp design(%{"kind" => "ab"} = design) do
    cohorts = design["cohorts"]
    errors = object(design, ~w(kind cohorts control), "design")

    if is_list(cohorts) do
      ids = Enum.map(cohorts, &cohort_id/1)

      errors ++
        if(length(cohorts) >= 2, do: [], else: [error("design.cohorts", "requires at least two cohorts")]) ++
        if(Enum.uniq(ids) == ids, do: [], else: [error("design.cohorts", "cohort ids must be unique")]) ++
        if(design["control"] in ids, do: [], else: [error("design.control", "must name a cohort")]) ++
        (cohorts |> Enum.with_index() |> Enum.flat_map(fn {cohort, index} -> cohort(cohort, "design.cohorts.#{index}") end))
    else
      errors ++ [error("design.cohorts", "must be a list")]
    end
  end

  defp design(_), do: [error("design.kind", "must be before_after or ab")]

  defp cohort_id(cohort) when is_map(cohort), do: cohort["id"]
  defp cohort_id(_cohort), do: nil

  defp cohort(cohort, path) do
    object(cohort, ~w(id label where), path) ++
      field(cohort, "id", &text?/1, "must be a nonempty string", path) ++
      field(cohort, "label", &text?/1, "must be a nonempty string", path) ++ Predicate.validate(if(is_map(cohort), do: cohort["where"], else: nil), path <> ".where")
  end

  defp metrics(metrics) when is_list(metrics) and metrics != [] do
    metrics
    |> Enum.with_index()
    |> Enum.flat_map(fn {metric, index} ->
      path = "metrics.#{index}"

      object(metric, ~w(ref direction primary min_samples mde kind), path, ~w(ref direction primary)) ++
        field(metric, "ref", &(is_binary(&1) and Regex.match?(~r/^[a-z0-9-]+\/[a-z0-9_]+$/, &1)), "invalid pack/metric reference", path) ++
        field(metric, "direction", &(&1 in ~w(decrease increase none)), "unknown expected direction", path) ++
        field(metric, "primary", &is_boolean/1, "must be a boolean", path) ++ optional_metric(metric, path)
    end)
  end

  defp metrics(_), do: [error("metrics", "requires at least one metric")]

  defp optional_metric(metric, path) when is_map(metric) do
    Enum.flat_map([{"min_samples", &positive?/1}, {"mde", &(is_number(&1) and &1 > 0)}, {"kind", &(&1 in ~w(duration count binary rate bucketed))}], fn {key, valid?} ->
      if Map.has_key?(metric, key), do: field(metric, key, valid?, "invalid metric #{key}", path), else: []
    end)
  end

  defp optional_metric(_, _), do: []

  defp windows(windows, %{"kind" => kind}) when kind in ~w(before_after ab) do
    keys = if kind == "ab", do: ~w(observation), else: ~w(before after)

    object(windows, keys, "windows") ++
      Enum.flat_map(keys, fn key ->
        window = if is_map(windows), do: windows[key], else: nil
        path = "windows.#{key}"

        object(window, ~w(start end), path) ++
          field(window, "start", &timestamp?/1, "must be a timestamp", path) ++
          field(window, "end", &optional_timestamp?/1, "must be a timestamp or null", path) ++ ordered(window, path)
      end)
  end

  defp windows(_, _), do: []

  defp ordered(%{"start" => start, "end" => stop}, path) when is_binary(start) and is_binary(stop) do
    with {:ok, first, _} <- DateTime.from_iso8601(start), {:ok, last, _} <- DateTime.from_iso8601(stop) do
      if DateTime.compare(first, last) == :lt, do: [], else: [error(path <> ".end", "must be after start")]
    else
      _ -> []
    end
  end

  defp ordered(_, _), do: []
  defp unique_attributes?(value), do: is_list(value) and Enum.uniq(value) == value and Enum.all?(value, &Predicate.attribute?/1)
  defp unique_strings?(value), do: is_list(value) and Enum.uniq(value) == value and Enum.all?(value, &is_binary/1)
end
