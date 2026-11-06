defmodule Aiur.BuildOrder.Epics.JournalValidation do
  @moduledoc """
  Strict decoding for one `epics.ndjson` record.

  The epic journal is a closed event set owned by `Aiur.BuildOrder.Features`, so
  each event is matched explicitly instead of through a generic schema. A record
  is the same versioned envelope as the feature journal: `v`, `seq`,
  `recorded_at`, `source`, `actor` and a non-empty `events` list. A `v` above 1
  reports `:version_unsupported` without being treated as corruption, so a newer
  build's records survive a rollback to this one.
  """

  alias Aiur.BuildOrder.Features.FeatureData

  @record_keys ~w(v seq recorded_at source actor events)
  @epic_keys ~w(slug label icon hue root)
  @change_keys ~w(label icon hue)
  @events %{
    "epic.created" => ~w(type epic at),
    "epic.updated" => ~w(type epic changes at),
    "epic.feature_added" => ~w(type epic feature at),
    "epic.feature_removed" => ~w(type epic feature at)
  }

  @spec record(term()) :: {:ok, map()} | {:error, term()}
  def record(%{"v" => version}) when is_integer(version) and version > 1, do: {:error, :version_unsupported}

  def record(%{"v" => 1} = value) when is_map(value) do
    with :ok <- exactly?(value, @record_keys),
         {:ok, seq} <- positive(value["seq"]),
         {:ok, at} <- date(value["recorded_at"]),
         {:ok, source} <- source(value["source"]),
         {:ok, actor} <- actor(value["actor"]),
         {:ok, events} <- events(value["events"]) do
      {:ok, %{v: 1, seq: seq, recorded_at: at, source: source, actor: actor, events: events}}
    end
  end

  def record(_), do: {:error, :invalid_record}

  defp events(values) when is_list(values) and values != [] do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case event(value) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp events(_), do: {:error, :invalid_record}

  defp event(%{"type" => type} = value) when is_map(value) do
    case Map.fetch(@events, type) do
      {:ok, keys} ->
        with :ok <- exactly?(value, keys), do: decode(type, value)

      :error ->
        {:error, :invalid_record}
    end
  end

  defp event(_), do: {:error, :invalid_record}

  defp decode("epic.created", %{"epic" => epic, "at" => at}) do
    with {:ok, epic} <- epic(epic), {:ok, at} <- date(at), do: {:ok, %{type: "epic.created", epic: epic, at: at}}
  end

  defp decode("epic.updated", %{"epic" => slug, "changes" => changes, "at" => at}) do
    with {:ok, slug} <- slug(slug),
         {:ok, changes} <- changes(changes),
         {:ok, at} <- date(at),
         do: {:ok, %{type: "epic.updated", epic: slug, changes: changes, at: at}}
  end

  defp decode(type, %{"epic" => epic, "feature" => feature, "at" => at}) do
    with {:ok, epic} <- slug(epic), {:ok, feature} <- slug(feature), {:ok, at} <- date(at) do
      {:ok, %{type: type, epic: epic, feature: feature, at: at}}
    end
  end

  defp decode(_type, _value), do: {:error, :invalid_record}

  defp epic(value) when is_map(value) do
    with :ok <- exactly?(value, @epic_keys),
         {:ok, slug} <- slug(value["slug"]),
         {:ok, label} <- label(value["label"]),
         {:ok, icon} <- optional_icon(value["icon"]),
         {:ok, hue} <- hue(value["hue"]),
         {:ok, root} <- optional_root(value["root"]) do
      {:ok, %{slug: slug, label: label, icon: icon, hue: hue, root: root}}
    end
  end

  defp epic(_), do: {:error, :invalid_record}

  defp changes(value) when is_map(value) and map_size(value) > 0 do
    with :ok <- only?(value, @change_keys),
         {:ok, _icon} <- optional_icon(Map.get(value, "icon", :absent)),
         {:ok, _label} <- label(Map.get(value, "label", "placeholder")),
         {:ok, _hue} <- hue(Map.get(value, "hue", 0)) do
      {:ok, decode_changes(value)}
    end
  end

  defp changes(_), do: {:error, :invalid_record}

  defp decode_changes(value) do
    changes = value |> Map.take(~w(label hue)) |> atomize()
    if Map.has_key?(value, "icon"), do: Map.put(changes, :icon, value["icon"]), else: changes
  end

  defp atomize(map), do: Map.new(map, fn {key, value} -> {String.to_existing_atom(key), value} end)
  defp optional_icon(:absent), do: {:ok, :absent}
  defp optional_icon(nil), do: {:ok, nil}
  defp optional_icon(value), do: if(Aiur.Heroicons.valid?(value), do: {:ok, value}, else: {:error, :invalid_record})
  defp optional_root(nil), do: {:ok, nil}
  defp optional_root(value) when is_integer(value) and value > 0 and value < 2_147_483_648, do: {:ok, value}
  defp optional_root(_), do: {:error, :invalid_record}
  defp positive(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive(_), do: {:error, :invalid_record}
  defp date(%DateTime{} = value), do: {:ok, value}

  defp date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, 0} -> {:ok, date}
      _ -> {:error, :invalid_record}
    end
  end

  defp date(_), do: {:error, :invalid_record}
  defp slug(value), do: valid(FeatureData.slug?(value), value)
  defp label(value), do: valid(FeatureData.text?(value, 80), value)
  defp hue(value), do: valid(FeatureData.hue?(value), value)
  defp source(value), do: valid(FeatureData.source?(value), value)
  defp actor(value), do: valid(FeatureData.text?(value, 100), value)
  defp valid(true, value), do: {:ok, value}
  defp valid(_false, _value), do: {:error, :invalid_record}

  defp exactly?(value, keys) do
    if is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys), do: :ok, else: {:error, :invalid_record}
  end

  defp only?(value, keys) do
    if is_map(value) and Enum.all?(Map.keys(value), &(&1 in keys)), do: :ok, else: {:error, :invalid_record}
  end
end
