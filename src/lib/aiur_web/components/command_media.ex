defmodule AiurWeb.Components.CommandMedia do
  @moduledoc """
  Accessible rendering for typed Command media.

  One component serves every Command consumer — the dashboard Command detail and
  its options, the inline Command cards in a conversation, and any embeddable
  surface — so an image, animated image, video or audio item looks and behaves
  the same everywhere. Items arrive as the public projection from
  `Aiur.Commands.Media.public/1`; a local file is an `attachment` reference that
  this component points at the authorized media route, never at a filesystem
  path.

  ## Accessibility and failure

  * A still or animated image always renders its required `alt` text, and the
    browser shows that text when the file fails to load.
  * Video and audio use native `controls`, which are keyboard operable without a
    custom key map, and take an `aria-label` from the caption or alt text. Their
    fallback content carries an "Open media" link for a client that cannot play
    the format.
  * An item whose locator cannot be resolved to a URL — no attachment id, or an
    attachment in a consumer with no Command context — renders an explicit
    unavailable panel instead of a broken element.
  """

  use Phoenix.Component

  attr(:items, :list, default: [])
  attr(:decision_id, :string, default: nil)
  attr(:label, :string, default: "Media")

  @spec command_media(map()) :: Phoenix.LiveView.Rendered.t()
  def command_media(assigns) do
    ~H"""
    <div :if={@items != []} class="command-media-group" role="group" aria-label={@label}>
      <figure :for={item <- @items} class={["command-media", "command-media--" <> kind(item)]}>
        <.media_element :if={item_source(item, @decision_id)} item={item} decision_id={@decision_id} />
        <div :if={!item_source(item, @decision_id)} class="command-media__unavailable" role="status">
          <strong>Media unavailable</strong>
          <span>{unavailable_hint(item)}</span>
        </div>
        <figcaption :if={caption(item)} class="command-media__caption">
          <span :if={kind(item) == "animated_image"} class="command-media__kind">Animated</span>
          {caption(item)}
        </figcaption>
      </figure>
    </div>
    """
  end

  attr(:item, :map, required: true)
  attr(:decision_id, :string, default: nil)

  defp media_element(%{item: %{"kind" => "image"}} = assigns) do
    assigns = assign(assigns, :src, item_source(assigns.item, assigns.decision_id))

    ~H"""
    <img src={@src} alt={alt(@item)} loading="lazy" decoding="async" width={dimension(@item, "width")} height={dimension(@item, "height")} />
    """
  end

  defp media_element(%{item: %{"kind" => "animated_image"}} = assigns) do
    assigns = assign(assigns, :src, item_source(assigns.item, assigns.decision_id))

    ~H"""
    <img src={@src} alt={alt(@item)} loading="lazy" decoding="async" width={dimension(@item, "width")} height={dimension(@item, "height")} />
    """
  end

  defp media_element(%{item: %{"kind" => "video"}} = assigns) do
    assigns = assign(assigns, :src, item_source(assigns.item, assigns.decision_id))
    assigns = assign(assigns, :poster, source(Map.get(assigns.item, "poster"), assigns.decision_id))

    ~H"""
    <video controls preload="metadata" playsinline poster={@poster} aria-label={accessible_name(@item)} width={dimension(@item, "width")} height={dimension(@item, "height")}>
      <source src={@src} type={Map.get(@item, "mime_type")} />
      <a href={@src}>Open video</a>
    </video>
    """
  end

  defp media_element(%{item: %{"kind" => "audio"}} = assigns) do
    assigns = assign(assigns, :src, item_source(assigns.item, assigns.decision_id))

    ~H"""
    <audio controls preload="metadata" aria-label={accessible_name(@item)}>
      <source src={@src} type={Map.get(@item, "mime_type")} />
      <a href={@src}>Open audio</a>
    </audio>
    """
  end

  defp media_element(assigns) do
    ~H"""
    <div class="command-media__unavailable" role="status">
      <strong>Media unavailable</strong>
      <span>{unavailable_hint(@item)}</span>
    </div>
    """
  end

  @doc """
  Resolves a whole media item to a browser URL. Items carry their reference in
  `locator`; `source/2` resolves one locator value on its own.
  """
  @spec item_source(term(), String.t() | nil) :: String.t() | nil
  def item_source(item, decision_id) when is_map(item) do
    source(Map.get(item, "locator") || Map.get(item, :locator), decision_id)
  end

  def item_source(_item, _decision_id), do: nil

  @doc """
  Resolves one item's locator to a browser URL.

  A validated https URL is used as-is; an attachment reference becomes the
  authorized Decision media route when the consumer knows its Command. Anything
  else is unavailable rather than a broken element.
  """
  @spec source(term(), String.t() | nil) :: String.t() | nil
  def source(nil, _decision_id), do: nil

  def source(%{"kind" => "url", "value" => value}, _decision_id) when is_binary(value), do: value

  def source(%{"kind" => "attachment", "attachment_id" => id}, decision_id)
      when is_binary(id) and is_binary(decision_id) do
    "/api/v1/decisions/#{decision_id}/media/#{id}"
  end

  def source(%{kind: :url, value: value}, _decision_id) when is_binary(value), do: value

  def source(%{kind: :path} = locator, decision_id) when is_binary(decision_id) do
    case Map.get(locator, :attachment_id) do
      id when is_binary(id) -> "/api/v1/decisions/#{decision_id}/media/#{id}"
      _missing -> nil
    end
  end

  def source(_locator, _decision_id), do: nil

  defp kind(item) when is_map(item) do
    case Map.get(item, "kind") do
      kind when is_binary(kind) -> kind
      _missing -> "unknown"
    end
  end

  defp kind(_item), do: "unknown"

  defp alt(item), do: Map.get(item, "alt_text") || caption(item) || "Command media"

  defp caption(item) when is_map(item), do: Map.get(item, "caption")

  defp caption(_item), do: nil

  defp accessible_name(item), do: Map.get(item, "alt_text") || caption(item) || "Command media"

  defp unavailable_hint(item) do
    case Map.get(item, "mime_type") do
      mime when is_binary(mime) -> "This #{mime} item could not be resolved."
      _missing -> "This media item could not be resolved."
    end
  end

  defp dimension(item, key) do
    case Map.get(item, key) do
      value when is_integer(value) and value > 0 -> value
      _missing -> nil
    end
  end
end
