defmodule Aiur.Experiments.Metric do
  @moduledoc "A metric definition shared by built-in and consumer packs."
  alias Aiur.Experiments.SpecFields, as: Fields
  @derive Jason.Encoder
  defstruct [:id, :pack, :label, :unit, :unit_of_analysis, :kind, :better, :default_direction, :group, :source, description: "", requires: []]
  @type t :: %__MODULE__{}

  @spec new(map(), String.t()) :: {:ok, t()} | {:error, [map()]}
  def new(attrs, pack) do
    errors =
      Fields.object(
        attrs,
        ~w(id label description unit unit_of_analysis kind better default_direction group requires source),
        "metric",
        ~w(id label unit unit_of_analysis kind better default_direction group requires)
      ) ++
        Fields.field(attrs, "id", &identifier?/1, "must be snake_case", "metric") ++
        Enum.flat_map(~w(label unit unit_of_analysis group), &Fields.field(attrs, &1, fn value -> Fields.text?(value) end, "must be a nonempty string", "metric")) ++
        Fields.field(attrs, "kind", &(&1 in ~w(duration count binary rate bucketed)), "unknown kind", "metric") ++
        Fields.field(attrs, "better", &(&1 in ~w(lower higher)), "must be lower or higher", "metric") ++
        Fields.field(attrs, "default_direction", &(&1 in ~w(increase decrease none)), "unknown direction", "metric") ++
        Fields.field(attrs, "requires", &strings?/1, "must be strings", "metric") ++
        optional_description(attrs)

    if errors == [] do
      values = Enum.map(attrs, fn {key, value} -> {String.to_existing_atom(key), value} end)
      {:ok, struct!(__MODULE__, Keyword.put(values, :pack, pack))}
    else
      {:error, errors}
    end
  end

  @spec identifier?(term()) :: boolean()
  def identifier?(value), do: is_binary(value) and Regex.match?(~r/^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$/, value)

  @spec strings?(term()) :: boolean()
  def strings?(value), do: is_list(value) and Enum.all?(value, &Fields.text?/1)

  defp optional_description(attrs) when is_map(attrs) do
    if Map.has_key?(attrs, "description"), do: Fields.field(attrs, "description", &is_binary/1, "must be a string", "metric"), else: []
  end

  defp optional_description(_), do: []
end
