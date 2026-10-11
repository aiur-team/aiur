defmodule Aiur.Experiments.Packs.Loader do
  @moduledoc false
  alias Aiur.Experiments.{Metric, SpecFields}

  @spec load(Path.t(), [String.t()], [String.t()]) :: {map(), [map()]}
  def load(root, dirs, reserved \\ ["delivery-speed"]) do
    Enum.reduce(dirs, {%{}, []}, fn dir, acc ->
      with true <- relative?(dir),
           {:ok, %{candidate: path}} <- Aiur.PathSafety.contained?(root, Path.expand(dir, root)) do
        path |> Path.join("*.json") |> Path.wildcard() |> Enum.sort() |> Enum.reduce(acc, &load_file(&1, &2, root, reserved))
      else
        _ -> add_problem(acc, dir, "pack directory must stay inside the base checkout")
      end
    end)
  end

  defp load_file(file, {packs, problems} = acc, root, reserved) do
    with {:ok, _} <- Aiur.PathSafety.contained?(root, file),
         {:ok, body} <- File.read(file),
         {:ok, json} <- Jason.decode(body),
         {:ok, pack} <- validate(json),
         false <- pack["id"] in reserved,
         false <- Map.has_key?(packs, pack["id"]) do
      {Map.put(packs, pack["id"], Map.put(pack, "file", file)), problems}
    else
      true -> add_problem(acc, file, "pack id collides with a built-in or another consumer pack")
      {:error, errors} when is_list(errors) -> {packs, problems ++ Enum.map(errors, &Map.put(&1, :file, file))}
      {:error, reason} -> add_problem(acc, file, "cannot load pack: #{inspect(reason)}")
    end
  end

  @spec validate(term()) :: {:ok, map()} | {:error, [map()]}
  def validate(json) do
    errors =
      SpecFields.object(json, ~w(schema_version id version metrics), "pack") ++
        SpecFields.field(json, "schema_version", &(&1 == 1), "must equal 1", "pack") ++
        SpecFields.field(json, "id", &pack_id?/1, "invalid pack id", "pack") ++
        SpecFields.field(json, "version", &SpecFields.text?/1, "must be a nonempty string", "pack")

    {metrics, metric_errors} = validate_metrics(if(is_map(json), do: json["metrics"], else: nil), if(is_map(json), do: json["id"], else: nil))

    case errors ++ metric_errors do
      [] -> {:ok, Map.put(json, "metrics", metrics)}
      all -> {:error, all}
    end
  end

  defp validate_metrics(metrics, pack) when is_list(metrics) and metrics != [] do
    {values, errors} =
      metrics
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {attrs, index}, {values, errors} ->
        case Metric.new(attrs, pack) do
          {:ok, metric} -> {values ++ [metric], errors ++ source_errors(metric.source, "metrics.#{index}.source")}
          {:error, failures} -> {values, errors ++ Enum.map(failures, &Map.update!(&1, :path, fn path -> "metrics.#{index}." <> path end))}
        end
      end)

    ids = Enum.map(values, & &1.id)
    duplicate = if length(ids) == length(Enum.uniq(ids)), do: [], else: [SpecFields.error("metrics", "duplicate metric id")]
    {values, errors ++ duplicate}
  end

  defp validate_metrics(_, _), do: {[], [SpecFields.error("metrics", "must be a nonempty array")]}
  defp pack_id?(id), do: is_binary(id) and Regex.match?(~r/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/, id)

  defp source_errors(%{"kind" => "event_interval"} = source, path) do
    SpecFields.object(source, ~w(kind start end unit_key attrs), path, ~w(kind start end unit_key)) ++
      topic_fields(source, ~w(start end), path) ++ unit_fields(source, path) ++ attr_fields(source, path)
  end

  defp source_errors(%{"kind" => "event_count"} = source, path) do
    choice = Map.has_key?(source, "unit_key") != Map.has_key?(source, "per")
    choice_errors = if choice, do: [], else: [SpecFields.error(path, "requires exactly one of unit_key or per")]

    SpecFields.object(source, ~w(kind match unit_key per attrs), path, ~w(kind match)) ++
      topic_fields(source, ~w(match), path) ++ choice_errors ++ count_unit_fields(source, path) ++ attr_fields(source, path)
  end

  defp source_errors(%{"kind" => "ndjson"} = source, path) do
    SpecFields.object(source, ~w(kind path), path) ++ SpecFields.field(source, "path", &relative?/1, "must be a contained relative path", path)
  end

  defp source_errors(%{"kind" => "script"} = source, path) do
    SpecFields.object(source, ~w(kind argv cwd), path) ++
      SpecFields.field(source, "argv", &(Metric.strings?(&1) and &1 != []), "must be nonempty argv strings", path) ++
      SpecFields.field(source, "cwd", &(&1 == "repo"), "must equal repo", path)
  end

  defp source_errors(_, path), do: [SpecFields.error(path, "unknown or missing source kind")]

  defp topic_fields(source, keys, path), do: Enum.flat_map(keys, &SpecFields.field(source, &1, fn value -> topic?(value) end, "invalid topic pattern", path))
  defp unit_fields(source, path), do: SpecFields.field(source, "unit_key", &unit_key?/1, "must be a JSON pointer or topic:index", path)

  defp count_unit_fields(source, path) do
    if Map.has_key?(source, "per"), do: SpecFields.field(source, "per", &(&1 in ~w(hour day)), "must be hour or day", path), else: unit_fields(source, path)
  end

  defp attr_fields(source, path) do
    case Map.get(source, "attrs", %{}) do
      attrs when is_map(attrs) ->
        Enum.flat_map(attrs, &attr_field(&1, path))

      _ ->
        [SpecFields.error(path <> ".attrs", "must be an object")]
    end
  end

  defp attr_field({name, pointer}, path) do
    if SpecFields.text?(name) and pointer?(pointer), do: [], else: [SpecFields.error(path <> ".attrs", "attributes must name JSON pointers")]
  end

  defp topic?(topic) when is_binary(topic), do: Regex.match?(~r/^(?:[a-zA-Z0-9_-]+|\*|#)(?:\.(?:[a-zA-Z0-9_-]+|\*|#))*$/, topic)
  defp topic?(_), do: false
  defp unit_key?("topic:" <> index), do: Regex.match?(~r/^\d+$/, index)
  defp unit_key?(value), do: pointer?(value)
  defp pointer?("/" <> rest), do: not Regex.match?(~r/~(?![01])/, rest)
  defp pointer?(_), do: false

  defp relative?("state:" <> relative), do: relative?(relative)

  defp relative?(value) when is_binary(value) do
    value != "" and not String.contains?(value, <<0>>) and Path.type(value) == :relative and ".." not in Path.split(value)
  end

  defp relative?(_), do: false
  defp add_problem({packs, problems}, file, message), do: {packs, problems ++ [%{file: file, path: "pack", message: message}]}
end
