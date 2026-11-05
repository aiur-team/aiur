defmodule Aiur.Commands.Media.Projection do
  @moduledoc """
  The projection half of the Command media contract.

  Two shapes leave the canonical boundary: `public/1` for an untrusted client
  (never a filesystem path, never a credential) and `to_json_safe/1` for
  durable storage (the validated artifact reference). Both are pure and total,
  so replaying an older snapshot yields the same projection the live Command
  yields.
  """

  alias Aiur.Commands.Media

  @doc "Attachment index for the media a Command carries on its prompt and options."
  @spec index([Media.item()], [map()]) :: %{String.t() => Media.item()}
  def index(prompt_media, options) do
    option_media =
      options
      |> Enum.flat_map(fn option -> Map.get(option, :media) || Map.get(option, "media") || [] end)
      |> Enum.filter(&is_map/1)

    (prompt_media ++ option_media)
    |> Enum.reduce(%{}, fn item, acc ->
      case Map.get(item, :attachment_id) do
        nil -> acc
        id -> Map.put_new(acc, id, item)
      end
    end)
  end

  @doc """
  The untrusted-client projection: no local filesystem paths, no credentials.

  A path locator is replaced by an `attachment` reference the client fetches
  through the authorized media route; a validated https URL is passed through.
  """
  @spec public(term()) :: [map()]
  def public(items) when is_list(items) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.map(&public_item/1)
  end

  def public(_items), do: []

  defp public_item(item) do
    %{
      "kind" => item |> fetch(:kind) |> name(),
      "mime_type" => fetch(item, :mime_type),
      "attachment_id" => fetch(item, :attachment_id),
      "alt_text" => fetch(item, :alt_text),
      "caption" => fetch(item, :caption),
      "byte_size" => fetch(item, :byte_size),
      "width" => fetch(item, :width),
      "height" => fetch(item, :height),
      "duration_ms" => fetch(item, :duration_ms),
      "locator" => public_locator(fetch(item, :locator)),
      "poster" => public_locator(fetch(item, :poster))
    }
  end

  defp public_locator(nil), do: nil
  defp public_locator(%{kind: :url, value: value}), do: %{"kind" => "url", "value" => value}
  defp public_locator(%{"kind" => "url", "value" => value}), do: %{"kind" => "url", "value" => value}
  defp public_locator(locator), do: %{"kind" => "attachment", "attachment_id" => Media.attachment_id(locator)}

  @doc """
  Durable option list for the canonical request snapshot.

  An option without media keeps exactly the shape it had before this contract
  existed, so a text-only request snapshot stays byte-identical.
  """
  @spec options_to_json_safe([map()]) :: [map()]
  def options_to_json_safe(options) when is_list(options) do
    Enum.map(options, fn option ->
      json = stringify(option)

      case fetch(option, :media) do
        media when is_list(media) and media != [] -> Map.put(json, "media", to_json_safe(media))
        _empty_or_missing -> Map.delete(json, "media")
      end
    end)
  end

  def options_to_json_safe(_options), do: []

  @doc """
  Adds a snapshot's prompt media to an already-stringified map.

  A text-only Decision keeps the exact persisted shape it had before this
  contract, so older snapshots and newer ones replay identically.
  """
  @spec put_snapshot_media(map(), term()) :: map()
  def put_snapshot_media(map, media) when is_list(media) and media != [],
    do: Map.put(map, "media", to_json_safe(media))

  def put_snapshot_media(map, _media), do: map

  @doc "Durable, JSON-safe storage shape; keeps the validated artifact reference."
  @spec to_json_safe(term()) :: [map()]
  def to_json_safe(items) when is_list(items) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn item ->
      %{
        "kind" => item |> fetch(:kind) |> name(),
        "mime_type" => fetch(item, :mime_type),
        "attachment_id" => fetch(item, :attachment_id),
        "alt_text" => fetch(item, :alt_text),
        "caption" => fetch(item, :caption),
        "byte_size" => fetch(item, :byte_size),
        "width" => fetch(item, :width),
        "height" => fetch(item, :height),
        "duration_ms" => fetch(item, :duration_ms),
        "locator" => json_locator(fetch(item, :locator)),
        "poster" => json_locator(fetch(item, :poster))
      }
    end)
  end

  def to_json_safe(_items), do: []

  defp json_locator(nil), do: nil
  defp json_locator(%{kind: kind, value: value}), do: %{"kind" => name(kind), "value" => value}
  defp json_locator(locator) when is_map(locator), do: locator
  defp json_locator(_locator), do: nil

  @doc "Reads one field from a durable or public media item, whichever key shape it has."
  @spec fetch_field(map(), atom()) :: term()
  def fetch_field(item, key), do: fetch(item, key)

  @doc "Resolves one attachment reference within a set of items, for serving."
  @spec find_attachment([Media.item()], String.t()) :: {:ok, Media.item()} | :error
  def find_attachment(items, attachment_id) when is_binary(attachment_id) do
    case Enum.find(items, &(fetch(&1, :attachment_id) == attachment_id)) do
      nil -> :error
      item -> {:ok, item}
    end
  end

  @doc "Every media item behind a prompt, its options and its recorded answers."
  @spec all_items(map()) :: [Media.item()]
  def all_items(decision) when is_map(decision) do
    prompt = Map.get(decision, :media) || []

    option_media =
      (Map.get(decision, :options) || [])
      |> Enum.flat_map(fn option -> Map.get(option, :media) || Map.get(option, "media") || [] end)
      |> Enum.filter(&is_map/1)

    answers =
      [Map.get(decision, :answer) | Enum.map(Map.get(decision, :revisions) || [], &Map.get(&1, :answer))]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(fn answer -> Map.get(answer, :media) || [] end)
      |> Enum.filter(&is_map/1)

    Enum.filter(prompt ++ option_media ++ answers, &is_map/1)
  end

  # Projection's own stringification, applied to a durable or struct option.
  defp stringify(option) when is_map(option) do
    option
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Map.new()
  end

  defp stringify(_option), do: %{}

  defp fetch(item, key) when is_map(item), do: Map.get(item, key, Map.get(item, Atom.to_string(key)))
  defp fetch(_item, _key), do: nil

  defp name(nil), do: nil
  defp name(value) when is_atom(value), do: Atom.to_string(value)
  defp name(value) when is_binary(value), do: value
  defp name(_value), do: nil
end
