defmodule Aiur.BuildOrder.Features.JournalValidation do
  @moduledoc false

  alias Aiur.BuildOrder.Features.FeatureData

  @enum_atoms %{"auto" => :auto, "explicit" => :explicit, "claimed" => :claimed, "first_observed" => :first_observed}

  @feature %{
    slug: :slug,
    label: :label,
    hue: :hue,
    hue_source: {:enum, ["auto", "explicit"]},
    epics: {:list, :epic},
    from: :time,
    to: :end_time,
    baseline: :baseline,
    public_ref: :public_ref,
    created_at: :date,
    updated_at: :date
  }
  @changes Map.take(@feature, [:label, :hue, :hue_source, :epics, :from, :to, :public_ref])
  @events %{
    "feature.created" => %{data: :feature},
    "feature.updated" => %{changes: :changes, at: :date},
    "feature.epic_added" => %{epic: :epic, at: :date},
    "member.added" => %{number: :number, epic: :key, at: :time, at_basis: {:enum, ["claimed", "first_observed"]}, confirmed: :boolean},
    "member.removed" => %{number: :number, at: :time, reason: {:string_enum, ["remove", "move"]}},
    "also.added" => %{number: :number, at: :time},
    "also.removed" => %{number: :number, at: :time},
    "baseline.set" => %{at: :date, members: {:list, :number}}
  }

  @spec record(term()) :: {:ok, map()} | {:error, term()}
  def record(value) do
    object(value, %{v: {:literal, 1}, seq: :positive, recorded_at: :date, source: :source, actor: :actor, events: {:list, :event}})
  end

  defp object(value, schema, optional? \\ false)

  defp object(value, schema, optional?) when is_map(value) do
    names = Enum.map(Map.keys(schema), &Atom.to_string/1)

    if Enum.all?(Map.keys(value), &(&1 in names)) and (optional? or map_size(value) == map_size(schema)) do
      decode_fields(value, schema)
    else
      {:error, :invalid_record}
    end
  end

  defp object(_, _, _), do: {:error, :invalid_record}

  defp decode_fields(value, schema) do
    Enum.reduce_while(value, {:ok, %{}}, fn {name, item}, {:ok, acc} ->
      key = Enum.find(Map.keys(schema), &(Atom.to_string(&1) == name))

      case field(item, schema[key]) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, key, decoded)}}
        error -> {:halt, error}
      end
    end)
  end

  defp field(%{"type" => type} = value, :event) when is_map_key(@events, type) do
    value = if type == "member.added", do: Map.put_new(value, "at_basis", "claimed"), else: value
    object(value, Map.merge(@events[type], %{type: {:literal, type}, feature: :slug}))
  end

  defp field(value, :feature), do: object(value, @feature)
  defp field(value, :changes), do: object(value, @changes, true)
  defp field(value, :epic), do: object(value, %{key: :key, label: :label})
  defp field("none", :baseline), do: {:ok, :none}

  defp field(value, :baseline) do
    with {:ok, baseline} <- object(value, %{at: :date, members: {:list, :number}}) do
      {:ok, %{baseline | members: MapSet.new(baseline.members)}}
    end
  end

  defp field("none", :public_ref), do: {:ok, :none}
  defp field(value, :public_ref), do: checked(value, FeatureData.public_ref?(value))
  defp field("none", :end_time), do: {:ok, :none}
  defp field(value, :end_time), do: field(value, :time)
  defp field("unknown", :time), do: {:ok, :unknown}
  defp field(value, :time), do: field(value, :date)

  defp field(value, :date) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, 0} -> {:ok, date}
      _ -> {:error, :invalid_record}
    end
  end

  defp field(value, :slug), do: checked(value, FeatureData.slug?(value))
  defp field(value, :key), do: checked(value, FeatureData.epic_key?(value))
  defp field(value, :source), do: checked(value, FeatureData.source?(value))
  defp field(value, :label), do: checked(value, FeatureData.text?(value, 80))
  defp field(value, :actor), do: checked(value, FeatureData.text?(value, 100))
  defp field(value, :hue), do: checked(value, FeatureData.hue?(value))
  defp field(value, :number) when is_integer(value) and value > 0 and value < 2_147_483_648, do: {:ok, value}
  defp field(value, :positive) when is_integer(value) and value > 0, do: {:ok, value}
  defp field(value, :boolean) when is_boolean(value), do: {:ok, value}
  defp field(value, {:literal, value}), do: {:ok, value}

  defp field(value, {:enum, values}) do
    if value in values, do: {:ok, Map.fetch!(@enum_atoms, value)}, else: {:error, :invalid_record}
  end

  defp field(value, {:string_enum, values}) do
    if value in values, do: {:ok, value}, else: {:error, :invalid_record}
  end

  defp field(values, {:list, type}) when is_list(values) and values != [] do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case field(value, type) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp field([], {:list, :number}), do: {:ok, []}
  defp field(_, _), do: {:error, :invalid_record}

  defp checked(value, true), do: {:ok, value}
  defp checked(_value, false), do: {:error, :invalid_record}
end
