defmodule Aiur.BuildOrder.Published.Pack do
  @moduledoc """
  Planning-pack records for `build-order.v1`.

  A pack declares workstreams, external gates and per-ticket relations. This
  module turns those declarations into the document's feature, gate, epic and
  root records, and resolves the ticket relations the edge builder joins on.
  """

  alias Aiur.BuildOrder.Published.{Document, Progress}
  alias Aiur.BuildOrder.SelectedRoot

  @spec pack_metadata(term()) :: map()
  def pack_metadata(%SelectedRoot{pack_metadata: metadata}) when is_map(metadata), do: metadata
  def pack_metadata(_selected), do: %{}

  @spec relation_records(map(), keyword()) :: map()
  def relation_records(metadata, opts) do
    declared =
      case Map.get(metadata, "ticket_relations") do
        %{} = relations -> normalize_relations(relations)
        _missing -> %{}
      end

    extra =
      case Keyword.get(opts, :relations) do
        %{} = relations -> normalize_relations(relations)
        _missing -> %{}
      end

    Map.merge(declared, extra)
  end

  # Pack metadata is written with atom keys internally and string keys when it
  # arrives from a decoded pack document; the encoder reads one shape.
  defp normalize_relations(relations) do
    Map.new(relations, fn
      {identifier, %{} = relation} ->
        {identifier, Map.new(relation, fn {key, value} -> {to_string(key), value} end)}

      {identifier, value} ->
        {identifier, value}
    end)
  end

  @spec gate_records(map(), keyword()) :: [map()]
  def gate_records(metadata, opts) do
    declared =
      metadata
      |> Map.get("external_gates", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&gate_record/1)

    extra =
      opts
      |> Keyword.get(:gates, [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&gate_record/1)

    (declared ++ extra)
    |> Enum.reject(&is_nil(&1["key"]))
    |> Enum.uniq_by(& &1["key"])
  end

  defp gate_record(gate) do
    key = Document.string(Map.get(gate, "key") || Map.get(gate, "id"))

    if is_binary(key) and key != "" do
      %{
        "key" => key,
        "title" => Document.string(Map.get(gate, "title")) || key,
        "owner" => Document.string(Map.get(gate, "owner")),
        "resolution_criteria" => Document.string(Map.get(gate, "resolution_criteria")),
        "status" => gate_status(Map.get(gate, "status"))
      }
    end
  end

  defp gate_status(status) when status in ~w(open approved rejected), do: status
  defp gate_status(_status), do: "open"

  @spec feature_records(map(), [map()]) :: map()
  def feature_records(metadata, rows) do
    declared =
      metadata
      |> Map.get("workstreams", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{}, &put_workstream(&2, &1, metadata))

    rows
    |> Enum.flat_map(fn row -> feature_labels(row.relation, row.member.labels) end)
    |> Enum.uniq()
    |> Enum.reduce(declared, fn key, acc -> Map.put_new(acc, key, label_feature(key)) end)
  end

  defp put_workstream(acc, workstream, metadata) do
    key = Document.string(Map.get(workstream, "id"))

    if is_binary(key) and key != "" do
      Map.put(acc, key, %{
        "key" => key,
        "title" => Document.string(Map.get(workstream, "title")) || Document.humanize(key),
        "label" => workstream_label(metadata, key),
        "epic" => nil,
        "icon" => Document.string(Map.get(workstream, "icon")),
        "hue" => nil,
        "url" => nil,
        "progress" => Progress.unknown("pending")
      })
    else
      acc
    end
  end

  defp workstream_label(metadata, key) do
    case get_in(metadata, ["label_projection", "workstreams", key]) do
      label when is_binary(label) -> label
      _missing -> "feature:" <> key
    end
  end

  defp label_feature(key) do
    %{
      "key" => key,
      "title" => Document.humanize(key),
      "label" => "feature:" <> key,
      "epic" => nil,
      "icon" => nil,
      "hue" => nil,
      "url" => nil,
      "progress" => Progress.unknown("pending")
    }
  end

  @spec feature_labels(map(), term()) :: [String.t()]
  def feature_labels(relation, labels) do
    declared =
      case Map.get(relation, "feature") do
        key when is_binary(key) -> [key]
        _missing -> []
      end

    declared ++ Enum.flat_map(List.wrap(labels), &Document.prefix_value(&1, "feature:"))
  end

  @spec feature_key(term(), map(), map()) :: String.t() | nil
  def feature_key(member, relation, features) do
    keys = feature_labels(relation, member.labels)

    Enum.find(keys, fn key -> is_binary(key) and Map.has_key?(features, key) end)
  end

  @spec epic_record(term(), String.t(), map()) :: map()
  def epic_record(selected, key, features) do
    %{
      "key" => key,
      "title" => selected.root.title,
      "label" => "build-order:" <> key,
      "url" => selected.root.url,
      "icon" => selected.root.icon,
      "hue" => nil,
      "features" => features |> Map.keys() |> Enum.sort(),
      "progress" => Progress.unknown("pending")
    }
  end

  @spec epic_key(map(), term()) :: String.t()
  def epic_key(metadata, selected) do
    slug = metadata |> Map.get("build_order_id") |> Document.slug()

    cond do
      is_binary(slug) ->
        slug

      is_binary(Document.identifier(selected.root.identity)) ->
        "root-" <> Document.identifier(selected.root.identity)

      true ->
        "build-order"
    end
  end

  @spec root_record(term(), String.t(), map()) :: map()
  def root_record(selected, key, metadata) do
    id = Document.identifier(selected.root.identity) || "unknown"

    %{
      "id" => id,
      "title" => selected.root.title,
      "number" => Document.number_or_nil(id),
      "url" => selected.root.url,
      "epic" => key,
      "plan_version" => Document.integer_or_nil(Map.get(metadata, "plan_version")),
      "researched_at_commit" => Document.string(Map.get(metadata, "researched_at_commit"))
    }
  end

  @spec build_order_id(map(), term()) :: String.t()
  def build_order_id(metadata, selected) do
    case Document.string(Map.get(metadata, "build_order_id")) do
      id when is_binary(id) and id != "" ->
        id

      _missing ->
        repository = Document.repository_name(selected.root.identity) || "unknown"
        repository <> ":build-order-" <> (Document.identifier(selected.root.identity) || "unknown")
    end
  end
end
