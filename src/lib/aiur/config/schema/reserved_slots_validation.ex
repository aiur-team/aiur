defmodule Aiur.Config.Schema.ReservedSlotsValidation do
  @moduledoc "Normalizer and changeset validator for `agent.reserved_slots`, a map of label to the slots held for it."

  import Ecto.Changeset, only: [validate_change: 3]

  @doc false
  @spec normalize_reserved_slots(nil | map()) :: map()
  def normalize_reserved_slots(nil), do: %{}

  def normalize_reserved_slots(slots) when is_map(slots),
    do: Map.new(slots, fn {label, count} -> {label |> to_string() |> String.trim() |> String.downcase(), count} end)

  @doc false
  @spec validate_reserved_slots(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_reserved_slots(changeset, field) do
    validate_change(changeset, field, fn ^field, slots ->
      Enum.flat_map(slots, fn
        {"", _count} -> [{field, "labels must not be blank"}]
        {_label, count} when is_integer(count) and count > 0 -> []
        {_label, _count} -> [{field, "counts must be positive integers"}]
      end)
    end)
  end
end
