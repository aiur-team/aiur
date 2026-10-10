defmodule AiurWeb.Build.PayloadValidator do
  @moduledoc false
  alias AiurWeb.Build.PayloadSchema, as: Schema

  @spec validate(map()) :: :ok | {:error, [{String.t(), atom()}]}
  def validate(message) do
    errors = check(message, {:object, Schema.message(message["kind"]), []}, "") ++ references(message) ++ page_rules(message)
    if errors == [], do: :ok, else: {:error, errors}
  end

  defp check(nil, {:nullable, _type}, _path), do: []
  defp check(value, {:nullable, type}, path), do: check(value, type, path)

  defp check(value, {:object, fields, optional}, path) when is_map(value) and is_map(fields) do
    unknown = Enum.flat_map(Map.keys(value) -- Map.keys(fields), &error(join(path, &1), :unknown))
    unknown ++ Enum.flat_map(fields, fn {key, type} -> field(value, key, type, optional, path) end)
  end

  defp check(value, {:dictionary, type}, path) when is_map(value), do: Enum.flat_map(value, fn {key, child} -> check(child, type, join(path, key)) end)
  defp check(value, {:list, type}, path) when is_list(value), do: value |> Enum.with_index() |> Enum.flat_map(fn {child, i} -> check(child, type, join(path, i)) end)
  defp check([a, b], {:pair, type}, path), do: check(a, type, join(path, 0)) ++ check(b, type, join(path, 1))
  defp check(value, {:enum, values}, path), do: if(value in values, do: [], else: error(path, :enum))
  defp check(value, {:literal, value}, _path), do: []
  defp check(value, {:integer_range, low, high}, _path) when is_integer(value) and value >= low and value <= high, do: []
  defp check(value, {:range, low, high}, _path) when is_number(value) and value >= low and value <= high, do: []
  defp check(value, :string, _path) when is_binary(value), do: []
  defp check(value, {:short_string, max}, path) when is_binary(value), do: if(String.length(value) <= max, do: [], else: error(path, :length))
  defp check(value, :integer, _path) when is_integer(value), do: []
  defp check(value, :positive, _path) when is_integer(value) and value > 0, do: []
  defp check(value, :nonnegative, _path) when is_integer(value) and value >= 0, do: []
  defp check(value, :number, _path) when is_number(value), do: []
  defp check(value, :boolean, _path) when is_boolean(value), do: []
  defp check(value, :id, path) when is_binary(value), do: if(Regex.match?(~r/^(?:[1-9][0-9]*|pack:[a-z0-9][a-z0-9-]{0,63})$/, value), do: [], else: error(path, :id))
  defp check(value, :model, path) when is_binary(value), do: if(Regex.match?(~r/^[a-z0-9][a-z0-9._-]{0,31}$/, value), do: [], else: error(path, :model))
  defp check(value, :usage, path) when is_map(value), do: check(value, {:object, Schema.usage(value["state"]), []}, path)
  defp check(value, :row, path) when is_map(value), do: check(value, {:object, Schema.row(), []}, path) ++ row_rules(value, path)
  defp check(_value, _type, path), do: error(path, :type)

  defp field(value, key, type, optional, path) do
    case Map.fetch(value, key) do
      {:ok, child} -> check(child, type, join(path, key))
      :error -> if(key in optional, do: [], else: error(join(path, key), :missing))
    end
  end

  defp row_rules(row, path) do
    []
    |> rule(row["sec"] != "plan" and row["cue"] != nil, join(path, "cue"), :section)
    |> rule(row["sec"] == "plan" and not is_map(row["cue"]), join(path, "cue"), :section)
    |> rule(row["sec"] == "plan" and row["wave"] != nil and (not is_integer(row["wave"]) or row["wave"] < 1), join(path, "wave"), :section)
    |> rule(row["sec"] == "hist" and not is_integer(row["end"]), join(path, "end"), :section)
    |> identity_rules(row, path)
  end

  defp identity_rules(errors, row, path) do
    errors
    |> rule(is_binary(row["id"]) and String.starts_with?(row["id"], "pack:") and row["num"] != nil, join(path, "num"), :identity)
    |> rule(is_binary(row["id"]) and not String.starts_with?(row["id"], "pack:") and row["id"] != to_string(row["num"]), join(path, "num"), :identity)
  end

  defp page_rules(%{"kind" => "earlier", "rows" => rows}) when is_list(rows) do
    rows |> Enum.with_index() |> Enum.flat_map(fn {row, i} -> if is_map(row) and row["sec"] == "hist", do: [], else: error("rows.#{i}.sec", :section) end)
  end

  defp page_rules(_message), do: []

  defp references(%{"kind" => "snapshot", "epics" => epics, "features" => features, "order" => order, "sections" => sections} = msg)
       when is_map(epics) and is_map(features) and is_list(order) and is_map(sections) do
    refs = Enum.flat_map(Enum.with_index(order), fn {key, i} -> reference(epics, key, "order.#{i}") end)
    refs ++ feature_refs(features, epics) ++ row_refs(sections, epics, features) ++ count_refs(msg["counts"], order, epics)
  end

  defp references(_message), do: []

  defp feature_refs(features, epics) do
    Enum.flat_map(features, fn {key, feature} ->
      if is_map(feature) and is_list(feature["epics"]), do: Enum.flat_map(feature["epics"], &reference(epics, &1, "features.#{key}.epics")), else: []
    end)
  end

  defp row_refs(sections, epics, features) do
    Enum.flat_map(sections, fn {sec, rows} -> section_refs(sec, rows, epics, features) end)
  end

  defp section_refs(sec, rows, epics, features) when is_list(rows) do
    rows |> Enum.with_index() |> Enum.flat_map(fn {row, i} -> ticket_refs(row, "sections.#{sec}.#{i}", sec, epics, features) end)
  end

  defp section_refs(_sec, _rows, _epics, _features), do: []

  defp ticket_refs(row, path, sec, epics, features) when is_map(row) do
    also = if is_list(row["also"]), do: Enum.flat_map(row["also"], &reference(features, &1, path <> ".also")), else: []

    also ++
      reference(epics, row["epic"], path <> ".epic") ++
      reference(features, row["feature"], path <> ".feature") ++
      if(row["sec"] == sec, do: [], else: error(path <> ".sec", :section))
  end

  defp ticket_refs(_row, _path, _sec, _epics, _features), do: []

  defp count_refs(counts, order, epics) when is_map(counts) do
    Enum.flat_map(Map.keys(counts), &reference(epics, &1, "counts.#{&1}")) ++ Enum.flat_map(order -- Map.keys(counts), &error("counts.#{&1}", :missing))
  end

  defp count_refs(_counts, _order, _epics), do: []
  defp reference(_map, nil, _path), do: []
  defp reference(map, key, path), do: if(Map.has_key?(map, key), do: [], else: error(path, :reference))
  defp rule(errors, true, path, reason), do: errors ++ error(path, reason)
  defp rule(errors, false, _path, _reason), do: errors
  defp join("", key), do: to_string(key)
  defp join(path, key), do: path <> "." <> to_string(key)
  defp error(path, reason), do: [{path, reason}]
end
