defmodule Aiur.Config.Schema.Experiments.Analyst do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-20 experiments.analyst.auto_request
    # @config-detail experiments.analyst.auto_request | boolean | true | Request analysts automatically; false keeps on-demand CLI analysis available. |
    field(:auto_request, :boolean, default: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs), do: schema |> cast(attrs, [:auto_request], empty_values: []) |> validate_required([:auto_request])
end
