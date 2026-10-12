defmodule Aiur.Experiments.Spec do
  @moduledoc "Validated v1 experiment specification; JSON fields retain string keys."
  alias Aiur.Experiments.{SpecDefaults, SpecValidation}
  @derive {Jason.Encoder, except: [:existing]}
  defstruct schema_version: 1,
            id: nil,
            key: nil,
            title: nil,
            hypothesis: "",
            owner: nil,
            status: "active",
            origin: nil,
            design: nil,
            metrics: [],
            min_samples: 15,
            alpha: 0.05,
            power_target: 0.8,
            windows: nil,
            filters: %{"all" => []},
            stratify_by: ["complexity"],
            tags: [],
            notes: "",
            created_at: nil,
            updated_at: nil,
            registered_at: nil,
            existing: false

  @type t :: %__MODULE__{}

  @spec new(map(), keyword() | map()) :: {:ok, t()} | {:error, [map()]}
  def new(attrs, defaults \\ [])

  def new(attrs, defaults) when is_map(attrs) do
    {map, resolution_errors} = SpecDefaults.prepare(attrs, defaults)

    case resolution_errors ++ SpecValidation.validate(map) do
      [] -> {:ok, struct!(__MODULE__, Enum.map(map, fn {key, value} -> {String.to_existing_atom(key), value} end))}
      errors -> {:error, errors}
    end
  end

  def new(_, _), do: {:error, [%{path: "spec", message: "must be an object"}]}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = spec), do: spec |> Map.from_struct() |> Map.delete(:existing) |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
end
