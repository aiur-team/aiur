defmodule Aiur.Config.Schema.Dashboard do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-22 dashboard.projects_home
    # @config-detail dashboard.projects_home | boolean | false | Serves the all-projects home at `/projects` and redirects a bare `/` to it. `/build` stays the Build page. |
    field(:projects_home, :boolean, default: false)
  end

  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs), do: cast(schema, attrs, [:projects_home])
end
