defmodule Aiur.Commands.Media do
  @moduledoc """
  Typed media contract for Command prompts, options and answers.

  A media item is one of four kinds — `image`, `animated_image`, `video`,
  `audio` — and carries the metadata a client needs to render it safely:
  a MIME type, a stable locator, and alt text or a caption. Nothing here is
  a second Command model: items travel inside the canonical request snapshot
  (`Aiur.Decision.media`, option `media`) and the canonical
  `Aiur.DecisionAnswer.media`.

  ## Two shapes, one boundary

  Ingress and durable storage keep the locator as an `Aiur.DecisionArtifact`
  reference (`%{kind: :path | :url, value: ...}`), validated against the safe
  roots exactly like `artifacts`. `public/1` is the untrusted-client shape: a
  path locator becomes an opaque `attachment` reference, so a dashboard or API
  consumer never learns a local filesystem path. Serving an attachment
  re-canonicalizes and re-checks containment at read time — validating at
  ingestion does not prove a later symlink swap has not reintroduced escape.

  ## Rejected media

  `normalize/2` returns the first failure as a stable, matchable atom pair.
  Expiring signed URLs are refused rather than persisted: a durable Command
  must not store a credential that stops working, and a refreshed URL is a new
  reference, not a rewrite of history.

  ## Backward compatibility

  `Decision`/`DecisionAnswer` content hashes only include media when at least
  one item is present, so a text-only v2 payload keeps the exact hash it had
  before this contract existed and replays unchanged.
  """

  alias Aiur.{DecisionArtifact, SecretRedactor}

  @kinds [:image, :animated_image, :video, :audio]

  @mime_types %{
    image: ~w(image/png image/jpeg image/webp image/avif),
    animated_image: ~w(image/gif image/webp image/apng image/avif),
    video: ~w(video/mp4 video/webm video/quicktime),
    audio: ~w(audio/mpeg audio/mp4 audio/aac audio/ogg audio/wav audio/webm)
  }

  @max_bytes %{
    image: 10 * 1_024 * 1_024,
    animated_image: 25 * 1_024 * 1_024,
    video: 250 * 1_024 * 1_024,
    audio: 50 * 1_024 * 1_024
  }

  @max_items 8
  @alt_text_max 400
  @caption_max 500
  @locator_max 4_096
  @attachment_prefix "med_"

  @signed_url_keys ~r/(signature|sig|token|expires|x-amz-|googleaccessid|key-pair-id|policy|credential|se=)/i

  @type kind :: :image | :animated_image | :video | :audio
  @type locator :: %{kind: :path | :url, value: String.t()}
  @type item :: %{
          kind: kind(),
          mime_type: String.t(),
          locator: locator(),
          attachment_id: String.t(),
          alt_text: String.t() | nil,
          caption: String.t() | nil,
          byte_size: non_neg_integer() | nil,
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          duration_ms: non_neg_integer() | nil,
          poster: locator() | nil
        }
  @type error ::
          {:media,
           :invalid_type
           | :too_many
           | :invalid_kind
           | :mime_type_missing
           | :mime_type_not_allowed
           | :locator_missing
           | :locator_too_long
           | :locator_not_allowed
           | :locator_expires
           | :byte_size_invalid
           | :too_large
           | :alt_text_required
           | :alt_text_too_long
           | :caption_too_long
           | :dimension_invalid
           | :duration_invalid
           | :poster_not_allowed
           | :poster_invalid
           | :attachment_unknown
           | :attachment_invalid}

  @doc "Allowed media kinds, in display order."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Allowed MIME types for one media kind."
  @spec mime_types(kind()) :: [String.t()]
  def mime_types(kind), do: Map.get(@mime_types, kind, [])

  @doc "Maximum bytes accepted for one media kind."
  @spec max_bytes(kind()) :: pos_integer()
  def max_bytes(kind), do: Map.fetch!(@max_bytes, kind)

  @doc "Whether `kind` is part of the contract."
  @spec kind?(term()) :: boolean()
  def kind?(kind), do: kind in @kinds

  @doc "Opaque, stable attachment identity for one validated locator."
  @spec attachment_id(locator()) :: String.t()
  def attachment_id(%{value: value}) do
    digest = :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> String.slice(0, 24)
    @attachment_prefix <> digest
  end

  @doc """
  Normalizes zero or more untrusted media items against the artifact boundary.

  Accepts the ingress shape (a bare locator string, or a `locator` map) and the
  durable shape written by `to_json_safe/1`, so replay re-validates the exact
  reference it stored instead of trusting a persisted shape.
  """
  @spec normalize(term(), [Path.t()]) :: {:ok, [item()]} | {:error, error()}
  def normalize(nil, _safe_roots), do: {:ok, []}
  def normalize([], _safe_roots), do: {:ok, []}

  def normalize(items, safe_roots) when is_list(items) and is_list(safe_roots) do
    if length(items) > @max_items do
      {:error, {:media, :too_many}}
    else
      collect(items, safe_roots)
    end
  end

  def normalize(_items, _safe_roots), do: {:error, {:media, :invalid_type}}

  defp collect(items, safe_roots) do
    Enum.reduce_while(items, {:ok, []}, fn raw, {:ok, acc} ->
      case normalize_item(raw, safe_roots) do
        {:ok, item} -> {:cont, {:ok, acc ++ [item]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_item(raw, safe_roots) when is_map(raw) do
    with {:ok, kind} <- kind(get(raw, :kind)),
         {:ok, mime_type} <- mime_type(kind, get(raw, :mime_type)),
         {:ok, alt_text} <- alt_text(kind, get(raw, :alt_text)),
         {:ok, caption} <- bounded(get(raw, :caption), @caption_max, :caption_too_long),
         {:ok, locator} <- locator(get(raw, :locator), safe_roots),
         {:ok, size} <- byte_limit(kind, get(raw, :byte_size)),
         {:ok, width} <- dimension(get(raw, :width)),
         {:ok, height} <- dimension(get(raw, :height)),
         {:ok, duration_ms} <- duration(kind, get(raw, :duration_ms)),
         {:ok, poster} <- poster(kind, get(raw, :poster), safe_roots) do
      {:ok,
       %{
         kind: kind,
         mime_type: mime_type,
         locator: locator,
         attachment_id: attachment_id(locator),
         alt_text: alt_text,
         caption: caption,
         byte_size: size,
         width: width,
         height: height,
         duration_ms: duration_ms,
         poster: poster
       }}
    end
  end

  defp normalize_item(_raw, _safe_roots), do: {:error, {:media, :invalid_type}}

  defp kind(kind) when kind in @kinds, do: {:ok, kind}

  defp kind(kind) when is_binary(kind) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == kind)) do
      nil -> {:error, {:media, :invalid_kind}}
      atom -> {:ok, atom}
    end
  end

  defp kind(_kind), do: {:error, {:media, :invalid_kind}}

  defp mime_type(_kind, nil), do: {:error, {:media, :mime_type_missing}}

  defp mime_type(kind, mime) when is_binary(mime) do
    normalized = mime |> String.trim() |> String.downcase()

    if normalized in mime_types(kind), do: {:ok, normalized}, else: {:error, {:media, :mime_type_not_allowed}}
  end

  defp mime_type(_kind, _mime), do: {:error, {:media, :mime_type_not_allowed}}

  # Alt text is the accessible name for a still or animated image; playable
  # media can lean on its caption and the player's own label instead.
  defp alt_text(kind, alt_text) when kind in [:image, :animated_image] do
    case bounded(alt_text, @alt_text_max, :alt_text_too_long) do
      {:ok, nil} -> {:error, {:media, :alt_text_required}}
      other -> other
    end
  end

  defp alt_text(_kind, alt_text), do: bounded(alt_text, @alt_text_max, :alt_text_too_long)

  defp bounded(nil, _max, _error), do: {:ok, nil}
  defp bounded("", _max, _error), do: {:ok, nil}

  defp bounded(value, max, error) when is_binary(value) do
    trimmed = String.trim(SecretRedactor.redact(value))

    cond do
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) > max -> {:error, {:media, error}}
      true -> {:ok, trimmed}
    end
  end

  defp bounded(_value, _max, error), do: {:error, {:media, error}}

  defp locator(nil, _safe_roots), do: {:error, {:media, :locator_missing}}

  defp locator(value, safe_roots) when is_binary(value), do: validate_locator(value, safe_roots)
  defp locator(%{} = raw, safe_roots), do: validate_locator(get(raw, :value), safe_roots)
  defp locator(_value, _safe_roots), do: {:error, {:media, :locator_not_allowed}}

  defp validate_locator(value, safe_roots) when is_binary(value) do
    cond do
      value == "" ->
        {:error, {:media, :locator_missing}}

      byte_size(value) > @locator_max ->
        {:error, {:media, :locator_too_long}}

      expiring_url?(value) ->
        {:error, {:media, :locator_expires}}

      true ->
        case DecisionArtifact.validate(value, safe_roots) do
          {:ok, locator} -> {:ok, locator}
          {:error, reason} -> {:error, {:media, artifact_error(reason)}}
        end
    end
  end

  defp validate_locator(_value, _safe_roots), do: {:error, {:media, :locator_not_allowed}}

  # A pre-signed URL stops working on its own schedule. Persisting one would
  # record a reference that silently rots, so it is refused at the boundary.
  defp expiring_url?(value) do
    String.starts_with?(value, "https://") and
      case URI.parse(value).query do
        nil -> false
        query -> Regex.match?(@signed_url_keys, query)
      end
  end

  defp artifact_error(:artifact_url_host_not_allowed), do: :locator_not_allowed
  defp artifact_error(:artifact_url_insecure_scheme), do: :locator_not_allowed
  defp artifact_error(:artifact_url_has_credentials), do: :locator_not_allowed
  defp artifact_error(:artifact_invalid), do: :locator_not_allowed
  defp artifact_error(reason), do: reason

  defp byte_limit(_kind, nil), do: {:ok, nil}

  defp byte_limit(kind, size) when is_integer(size) and size > 0 do
    if size > max_bytes(kind), do: {:error, {:media, :too_large}}, else: {:ok, size}
  end

  defp byte_limit(_kind, _size), do: {:error, {:media, :byte_size_invalid}}

  defp dimension(nil), do: {:ok, nil}
  defp dimension(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp dimension(_value), do: {:error, {:media, :dimension_invalid}}

  defp duration(_kind, nil), do: {:ok, nil}

  defp duration(kind, value) when kind in [:video, :animated_image, :audio] and is_integer(value) and value > 0,
    do: {:ok, value}

  defp duration(_kind, _value), do: {:error, {:media, :duration_invalid}}

  defp poster(_kind, nil, _safe_roots), do: {:ok, nil}

  defp poster(kind, value, safe_roots) when kind in [:video, :audio] do
    locator(value, safe_roots)
  end

  defp poster(_kind, _value, _safe_roots), do: {:error, {:media, :poster_not_allowed}}

  @doc """
  Validates the media list submitted with an answer.

  An answer may repeat media the Command already carries (by `attachment_id`,
  the only reference an untrusted client is given) or submit a fully typed
  item. `index` maps known attachment ids to items; pass `nil` when replaying a
  persisted answer, where the item is already resolved and hashed.
  """
  @spec normalize_answer(term(), %{String.t() => item()} | nil, [Path.t()]) :: {:ok, [item()]} | {:error, error()}
  def normalize_answer(nil, _index, _safe_roots), do: {:ok, []}
  def normalize_answer([], _index, _safe_roots), do: {:ok, []}

  def normalize_answer(items, index, safe_roots) when is_list(items) and is_list(safe_roots) do
    if length(items) > @max_items do
      {:error, {:media, :too_many}}
    else
      collect_answers(items, index, safe_roots)
    end
  end

  def normalize_answer(_items, _index, _safe_roots), do: {:error, {:media, :invalid_type}}

  defp collect_answers(items, index, safe_roots) do
    Enum.reduce_while(items, {:ok, []}, fn raw, {:ok, acc} ->
      case answer_item(raw, index, safe_roots) do
        {:ok, item} -> {:cont, {:ok, acc ++ [item]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # A replay passes no index: the item is already resolved, so re-validate the
  # whole reference instead of resolving it again against a Command snapshot
  # that may since have been superseded.
  defp answer_item(raw, index, safe_roots) when is_map(raw) do
    case {Map.get(raw, :attachment_id) || Map.get(raw, "attachment_id"), index} do
      {_id, nil} -> normalize_item(raw, safe_roots)
      {nil, _index} -> normalize_item(raw, safe_roots)
      {id, index} when is_binary(id) -> resolve_attachment(id, index, raw)
    end
  end

  defp answer_item(_raw, _index, _safe_roots), do: {:error, {:media, :invalid_type}}

  defp resolve_attachment(id, nil, _raw) when is_binary(id), do: {:error, {:media, :attachment_unknown}}

  defp resolve_attachment(id, index, raw) when is_map(index) do
    case Map.fetch(index, id) do
      {:ok, item} -> {:ok, merge_answer_overrides(item, raw)}
      :error -> {:error, {:media, :attachment_unknown}}
    end
  end

  defp merge_answer_overrides(item, raw) do
    case bounded(get(raw, :caption), @caption_max, :caption_too_long) do
      {:ok, nil} -> item
      {:ok, caption} -> Map.put(item, :caption, caption)
      {:error, _reason} -> item
    end
  end

  # Every caller hands this a decoded map — the canonical boundary rejects
  # non-map items before it gets here — so there is no non-map fallback clause.
  defp fetch(item, key) when is_map(item), do: Map.get(item, key, Map.get(item, Atom.to_string(key)))

  defp get(raw, key), do: fetch(raw, key)

  # The projection half of the contract — what a client renders and what the
  # store persists — lives in `Aiur.Commands.Media.Projection`.
  defdelegate index(prompt_media, options), to: Aiur.Commands.Media.Projection
  defdelegate public(items), to: Aiur.Commands.Media.Projection
  defdelegate to_json_safe(items), to: Aiur.Commands.Media.Projection
  defdelegate options_to_json_safe(options), to: Aiur.Commands.Media.Projection
  defdelegate put_snapshot_media(map, media), to: Aiur.Commands.Media.Projection
  defdelegate fetch_field(item, key), to: Aiur.Commands.Media.Projection
  defdelegate find_attachment(items, attachment_id), to: Aiur.Commands.Media.Projection
  defdelegate all_items(decision), to: Aiur.Commands.Media.Projection
end
