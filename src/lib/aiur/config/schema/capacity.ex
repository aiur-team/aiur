defmodule Aiur.Config.Schema.Capacity do
  @moduledoc """
  Project (L3) tightening of the machine capacity policy. Only `limits`,
  `reserve.percent` and `last_resort` are accepted; `Aiur.Config.CapacityPolicy.TightenCheck`
  refuses a value that loosens `~/.aiur/machine`.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Aiur.Config.CapacityPolicy

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field(:sources, :map, default: %{})
    field(:limits, :map, default: %{})
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:sources, :limits])
    |> top_level_errors(attrs)
    |> validate_change(:sources, &CapacityPolicy.source_errors(&1, &2, :project))
    |> validate_change(:limits, &CapacityPolicy.limit_errors/2)
  end

  # `cast/3` silently drops unknown keys; a typo here would leave a money cap unapplied.
  defp top_level_errors(changeset, attrs) when is_map(attrs) do
    attrs
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in ~w(sources limits)))
    |> Enum.sort()
    |> Enum.reduce(changeset, fn
      key, acc when key in ~w(default_burn_percent_per_hour max_agents) ->
        add_error(acc, :capacity, "#{key} is machine-owned; set it in ~/.aiur/machine")

      key, acc ->
        add_error(acc, :capacity, "#{key} is an unknown key")
    end)
  end

  defp top_level_errors(changeset, _attrs), do: changeset
end
