defmodule Aiur.Config.Schema.Lane do
  @moduledoc """
  One configured lane: a technical column such as frontend, backend or docs.

  A lane is matched by its GitHub label matchers, and a ticket labelled
  `lane:<key>`, `area:<key>` or `build-lane:<key>` also lands in the lane
  carrying that key. See `Aiur.Lane` for ticket-to-lane resolution.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Aiur.Heroicons

  @primary_key false

  embedded_schema do
    # @config-reference config-configuration-build-order-00 build_order.lanes.key
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail build_order.lanes.key | string | required | Lowercase identifier (letters, digits, dash, underscore); starts with a letter or digit. Must be unique; `unsorted` is reserved. |
    field(:key, :string)
    # @config-reference config-configuration-build-order-00 build_order.lanes.label
    # @config-detail build_order.lanes.label | string | required | Column header text, without control characters. |
    field(:label, :string)
    # @config-reference config-configuration-build-order-00 build_order.lanes.labels
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail build_order.lanes.labels | array | `[]` | GitHub label matchers, trimmed, downcased and deduplicated. A label may belong to one lane only. `epic:` matchers are refused because they mark parked tickets. |
    field(:labels, {:array, :string}, default: [])
    # @config-reference config-configuration-build-order-00 build_order.lanes.hue
    # @config-detail build_order.lanes.hue | integer | required | Colour hue, 0–359. |
    field(:hue, :integer)
    # @config-reference config-configuration-build-order-00 build_order.lanes.icon
    # @config-detail build_order.lanes.icon | string | required | A Heroicons v2 outline name. Legacy `bug`, `pen`, `server` and `docs` aliases keep their existing appearance (`bug-ant`, `paint-brush`, `server-stack`, `book-open`). |
    field(:icon, :string)
  end

  @spec icons() :: [String.t()]
  def icons, do: Heroicons.names() ++ ~w(bug pen server docs)

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(lane, attrs) do
    lane
    |> cast(attrs, [:key, :label, :labels, :hue, :icon], empty_values: [])
    |> validate_required([:key, :label, :hue, :icon])
    |> validate_format(:key, ~r/\A[a-z0-9][a-z0-9_-]*\z/, message: "must be a lowercase identifier (letters, digits, dash, underscore)")
    |> validate_exclusion(:key, ["unsorted"], message: "is reserved for the column of tickets with no lane")
    |> validate_change(:label, &validate_label/2)
    |> validate_number(:hue, greater_than_or_equal_to: 0, less_than: 360)
    |> validate_change(:icon, &validate_icon/2)
    |> validate_change(:labels, &validate_labels/2)
    |> update_change(:labels, &normalize_labels/1)
  end

  defp validate_icon(:icon, icon) do
    if Heroicons.valid?(icon), do: [], else: [icon: "is invalid"]
  end

  defp validate_label(:label, label) do
    if Enum.any?(String.to_charlist(label), &(&1 < 0x20 or &1 == 0x7F)),
      do: [label: "must not contain control characters"],
      else: []
  end

  defp validate_labels(:labels, labels) do
    normalized = normalize_labels(labels)

    cond do
      "" in normalized ->
        [labels: "must not contain a blank label"]

      Enum.any?(normalized, &String.starts_with?(&1, "epic:")) ->
        [labels: "must not use the epic: prefix; IssueSync treats epic:* labels as deliberate parking and stops healing those tickets"]

      true ->
        []
    end
  end

  @doc "Whether a ticket's labels are listed as matchers of this lane."
  @spec matches?(map(), list() | nil) :: boolean()
  def matches?(%{labels: matchers}, labels) do
    labels = normalize_labels(labels)
    Enum.any?(normalize_labels(matchers), &(&1 in labels))
  end

  @spec normalize_labels([String.t() | nil]) :: [String.t()]
  def normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(fn
      nil -> ""
      label -> label |> String.trim() |> String.downcase()
    end)
    |> Enum.uniq()
  end

  def normalize_labels(_labels), do: []
end
