defmodule Aiur.Config.Schema.Instance.Ignore do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-00 instance.ignore.tickets, instance.ignore.labels, instance.ignore.label_prefixes
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail instance.ignore.tickets, instance.ignore.labels, instance.ignore.label_prefixes | list of integers / strings | `[]` | Tickets another instance owns: listed numbers, tickets carrying a listed label, or tickets with a `<prefix>:*` label for a listed prefix (that instance's `tracker.github.label_prefix`). This daemon does not transition, land, withdraw, alert on, count, or wake its Executor for them; dispatch is unaffected. Hot-reloadable. |
    field(:tickets, {:array, :integer}, default: [])
    field(:labels, {:array, :string}, default: [])
    field(:label_prefixes, {:array, :string}, default: [])
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs), do: cast(schema, attrs, [:tickets, :labels, :label_prefixes], empty_values: [nil])
end

defmodule Aiur.Config.Schema.Instance do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-00 instance.role
    # @config-detail instance.role | string | `primary` | `secondary` disables repository-wide landing, quarantine, merge-queue and main-branch watchers while retaining ticket dispatch and per-ticket CI handling. Read once at daemon start; change it with a restart. |
    field(:role, :string, default: "primary")
    embeds_one(:ignore, Aiur.Config.Schema.Instance.Ignore, on_replace: :update, defaults_to_struct: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:role], empty_values: [])
    |> validate_inclusion(:role, ["primary", "secondary"])
    |> cast_embed(:ignore, with: &Aiur.Config.Schema.Instance.Ignore.changeset/2)
  end
end
