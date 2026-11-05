defmodule AiurWeb.Conversation.Minimap do
  @moduledoc """
  Right-edge transcript minimap rows derived from the conversation's jump anchors.

  The rows are the rendering input for the extracted embeddable component's
  minimap. A row carries the anchor position and kind so a tick stays a link into
  the transcript; transcript positions remain on the transcript rows, so the
  minimap never invents a second position model.
  """

  alias Aiur.Conversation.JumpPoints

  @limit 200

  @type row :: %{pos: pos_integer(), kind: String.t(), at: String.t() | nil, label: String.t()}

  @doc """
  Minimap rows for the given anchors, bounded to the newest #{@limit}.

  Anchors without an integer position are dropped: a tick that cannot jump
  anywhere would be a dead control.
  """
  @spec rows(term()) :: [row()]
  def rows(anchors) when is_list(anchors) do
    anchors
    |> Enum.filter(&is_integer(Map.get(&1, "pos")))
    |> Enum.map(&row/1)
    |> Enum.take(-@limit)
  end

  def rows(_anchors), do: []

  defp row(anchor) do
    kind = anchor["kind"] || "event"

    %{
      pos: anchor["pos"],
      kind: kind,
      at: get_in(anchor, ["event", "observed_at"]),
      label: anchor["label"] || catalogue_label(kind)
    }
  end

  defp catalogue_label(kind) do
    case JumpPoints.entry(kind) do
      %{label: label} -> label
      nil -> "Event"
    end
  end
end
