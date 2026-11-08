defmodule Aiur.Machine.Settings.Schema do
  @moduledoc "Embedded machine settings tree, independent of workflow configuration."
  use Ecto.Schema
  alias Aiur.Machine.Settings.Schema.{Capacity, Coordination, Gateway, Mobile, Pairing, Project, Transport}
  alias Aiur.Machine.Settings.Validation

  @primary_key false
  embedded_schema do
    embeds_one(:mobile, Mobile, defaults_to_struct: true, on_replace: :update)
    embeds_one(:gateway, Gateway, defaults_to_struct: true, on_replace: :update)
    embeds_one(:pairing, Pairing, defaults_to_struct: true, on_replace: :update)
    embeds_one(:transport, Transport, defaults_to_struct: true, on_replace: :update)
    embeds_many(:projects, Project, on_replace: :delete)
    embeds_one(:capacity, Capacity, defaults_to_struct: true, on_replace: :update)
    embeds_one(:coordination, Coordination, defaults_to_struct: true, on_replace: :update)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> Validation.cast(attrs)
    |> duplicates(:repo, "a repo is listed more than once", &String.downcase/1)
    |> duplicates(:config, "a config path is listed more than once", & &1)
  end

  # Messages are static: they must not echo a checkout path.
  defp duplicates(changeset, field, message, normalize) do
    values =
      for project <- Ecto.Changeset.get_change(changeset, :projects, []),
          project.valid?,
          value = Ecto.Changeset.get_field(project, field),
          do: normalize.(value)

    if length(values) == length(Enum.uniq(values)), do: changeset, else: Ecto.Changeset.add_error(changeset, :projects, message)
  end
end
