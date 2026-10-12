defmodule Aiur.Config.Schema.GeneralEpic do
  @moduledoc "One configured general epic, with normalized GitHub label matchers."

  use Ecto.Schema

  import Ecto.Changeset

  @icons ~w(bug pen server docs)
  @primary_key false

  embedded_schema do
    field(:key, :string)
    field(:label, :string)
    field(:labels, {:array, :string}, default: [])
    field(:hue, :integer)
    field(:icon, :string)
  end

  @spec icons() :: [String.t()]
  def icons, do: @icons

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(epic, attrs) do
    epic
    |> cast(attrs, [:key, :label, :labels, :hue, :icon], empty_values: [])
    |> validate_required([:key, :label, :hue, :icon])
    |> validate_format(:key, ~r/\A[a-z0-9][a-z0-9_-]*\z/, message: "must be a lowercase identifier (letters, digits, dash, underscore)")
    |> validate_exclusion(:key, ["unsorted"], message: "is reserved for the column of tickets with no epic")
    |> validate_change(:label, &validate_label/2)
    |> validate_number(:hue, greater_than_or_equal_to: 0, less_than: 360)
    |> validate_inclusion(:icon, @icons)
    |> validate_change(:labels, &validate_labels/2)
    |> update_change(:labels, &normalize_labels/1)
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

  defp normalize_labels(labels) do
    labels
    |> Enum.map(fn
      nil -> ""
      label -> label |> String.trim() |> String.downcase()
    end)
    |> Enum.uniq()
  end
end
