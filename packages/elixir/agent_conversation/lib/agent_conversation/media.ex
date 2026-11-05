defmodule AgentConversation.Media do
  @moduledoc """
  Inline artifacts an entry can carry: images, animated images, video and audio.

  The component renders a `<figure>` for every classified artifact and a text
  fallback when it cannot. A fallback is never invisible: an artifact of an
  unknown kind, one without a source, or one whose URL the host refuses still
  appears with its name, so a reader knows something was attached.

  Only `http` and `https` URLs are ever used as a `src`. A `data:` or `javascript:`
  URL is refused by scheme, and a host may narrow that further with a host
  allowlist.
  """

  @kinds [:image, :animated_image, :video, :audio]
  @schemes ["http", "https"]

  @type t :: %{
          kind: atom(),
          url: String.t() | nil,
          poster: String.t() | nil,
          alt: String.t(),
          fallback: boolean(),
          reason: atom() | nil
        }

  @doc "Every artifact kind the component renders inline."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Classifies one artifact.

  Options:

    * `:hosts` - when given, only these hosts may serve the artifact, which is how
      an embed keeps attachments on its own asset host,
    * `:kind` - an override for a payload that does not state one.

  Returns `:kind`, `:url`, `:poster`, `:alt`, `:fallback` and `:reason`. A refused
  or missing source leaves `:url` nil so no component can render it by accident.
  """
  @spec classify(map(), keyword()) :: t()
  def classify(artifact, opts \\ [])

  def classify(artifact, opts) when is_map(artifact) do
    url = source(artifact)
    alt = alt(artifact)
    kind = kind(Map.get(artifact, :kind) || Map.get(artifact, "kind") || opts[:kind], url)

    with {:ok, url} <- permitted(url, opts[:hosts]) do
      case kind do
        nil ->
          %{kind: :unsupported, url: url, poster: nil, alt: alt, fallback: true, reason: :unsupported_kind}

        kind ->
          %{
            kind: kind,
            url: url,
            poster: permitted_poster(artifact, opts[:hosts]),
            alt: alt,
            fallback: false,
            reason: nil
          }
      end
    else
      {:error, :missing_source} -> fallback(nil, alt, :missing_source)
      {:error, reason} -> fallback(nil, alt, reason)
    end
  end

  def classify(_artifact, _opts), do: fallback(nil, "Attachment", :unsupported_kind)

  @doc "Classifies every artifact in a list, dropping entries that are not maps."
  @spec classify_all(term(), keyword()) :: [t()]
  def classify_all(artifacts, opts \\ [])

  def classify_all(artifacts, opts) when is_list(artifacts) do
    artifacts |> Enum.filter(&is_map/1) |> Enum.map(&classify(&1, opts))
  end

  def classify_all(_artifacts, _opts), do: []

  @doc """
  The alternative text for an artifact.

  It always names the kind, so a screen reader announces "Image: capture.png"
  rather than a bare filename.
  """
  @spec alt(map()) :: String.t()
  def alt(artifact) when is_map(artifact) do
    name = artifact |> first(["alt", "name", "title"]) |> Kernel.||("Attachment")
    "#{kind_label(kind(Map.get(artifact, :kind) || Map.get(artifact, "kind"), source(artifact)))}: #{name}"
  end

  def alt(_artifact), do: "Attachment"

  defp fallback(url, alt, reason) do
    %{kind: :unsupported, url: url, poster: nil, alt: alt, fallback: true, reason: reason}
  end

  defp kind(stated, url) do
    case stated do
      "image" -> :image
      "gif" -> :animated_image
      "animated_image" -> :animated_image
      "video" -> :video
      "audio" -> :audio
      atom when atom in @kinds -> atom
      _other -> guess_kind(url)
    end
  end

  defp guess_kind(nil), do: nil

  defp guess_kind(url) do
    path = url |> URI.parse() |> Map.get(:path) |> to_string() |> String.downcase()

    cond do
      String.ends_with?(path, [".gif", ".apng", ".webp"]) -> :animated_image
      String.ends_with?(path, [".png", ".jpg", ".jpeg", ".avif", ".svg"]) -> :image
      String.ends_with?(path, [".mp4", ".webm", ".mov"]) -> :video
      String.ends_with?(path, [".mp3", ".wav", ".ogg", ".m4a", ".flac"]) -> :audio
      true -> nil
    end
  end

  defp kind_label(:image), do: "Image"
  defp kind_label(:animated_image), do: "Animated image"
  defp kind_label(:video), do: "Video"
  defp kind_label(:audio), do: "Audio"
  defp kind_label(_kind), do: "Attachment"

  defp source(artifact), do: first(artifact, ["url", "src"])

  defp permitted_poster(artifact, hosts) do
    case permitted(first(artifact, ["poster"]), hosts) do
      {:ok, url} -> url
      {:error, _reason} -> nil
    end
  end

  defp permitted(nil, _hosts), do: {:error, :missing_source}

  defp permitted(url, hosts) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in @schemes -> {:error, :scheme}
      is_nil(uri.host) -> {:error, :missing_source}
      hosts != nil and uri.host not in List.wrap(hosts) -> {:error, :host_not_allowed}
      true -> {:ok, url}
    end
  end

  defp first(artifact, keys), do: Enum.find_value(keys, &string(artifact, &1))

  defp string(artifact, key) do
    case Map.get(artifact, key) || Map.get(artifact, existing_atom(key)) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__unknown__
  end
end
