defmodule Aiur.Config.Schema.Decisions do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @max_allowed_kinds 100
  @max_kind_length 100

  @primary_key false

  @type t :: %__MODULE__{
          supervisor_allowed_kinds: [String.t()],
          supervisor_allow_non_reversible: boolean()
        }

  embedded_schema do
    field(:supervisor_allowed_kinds, {:array, :string}, default: [])
    field(:supervisor_allow_non_reversible, :boolean, default: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:supervisor_allowed_kinds, :supervisor_allow_non_reversible], empty_values: [])
    |> validate_change(:supervisor_allowed_kinds, &validate_allowed_kinds/2)
    |> update_change(:supervisor_allowed_kinds, &normalize_allowed_kinds/1)
  end

  defp validate_allowed_kinds(field, kinds) when length(kinds) > @max_allowed_kinds do
    [{field, "must contain at most #{@max_allowed_kinds} kinds"}]
  end

  defp validate_allowed_kinds(field, kinds) do
    if Enum.all?(kinds, &valid_kind?/1) do
      []
    else
      [{field, "must contain non-empty kinds of at most #{@max_kind_length} characters without control characters"}]
    end
  end

  defp valid_kind?(kind) when is_binary(kind) do
    trimmed = String.trim(kind)
    trimmed != "" and String.length(trimmed) <= @max_kind_length and not unsafe_control_chars?(kind)
  end

  defp valid_kind?(_kind), do: false

  defp normalize_allowed_kinds(kinds) do
    kinds
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp unsafe_control_chars?(text) do
    text
    |> String.to_charlist()
    |> Enum.any?(&(&1 < 0x20 or &1 == 0x7F))
  end
end
