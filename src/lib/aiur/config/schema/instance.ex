defmodule Aiur.Config.Schema.Instance.Ignore do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-00 instance.ignore.tickets
    # @config-detail instance.ignore.tickets | array of integers | `[]` | Ticket numbers another instance owns. This daemon does not transition, land, withdraw, alert on, count, or wake its Executor for them; dispatch is unaffected. Hot-reloadable. |
    field(:tickets, {:array, :integer}, default: [])

    # @config-reference config-configuration-00 instance.ignore.labels
    # @config-detail instance.ignore.labels | array of strings | `[]` | Exact labels marking tickets another instance owns. If label data is unavailable, ticket-scoped observers skip conservatively. This daemon does not transition, land, withdraw, alert on, count, or wake its Executor for them; dispatch is unaffected. Hot-reloadable. |
    field(:labels, {:array, :string}, default: [])

    # @config-reference config-configuration-00 instance.ignore.label_prefixes
    # @config-detail instance.ignore.label_prefixes | array of strings | `[]` | Label prefixes marking tickets another instance owns. A prefix such as `nuc` matches `nuc:*` state labels. If label data is unavailable, ticket-scoped observers skip conservatively. This daemon does not transition, land, withdraw, alert on, count, or wake its Executor for them; dispatch is unaffected. Hot-reloadable. |
    field(:label_prefixes, {:array, :string}, default: [])
  end

  @type t :: %__MODULE__{
          tickets: [integer()],
          labels: [String.t()],
          label_prefixes: [String.t()]
        }

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs),
    do: cast(schema, attrs, [:tickets, :labels, :label_prefixes], empty_values: [nil])
end

defmodule Aiur.Config.Schema.Instance do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Aiur.Config.Schema.Instance.Ignore

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-00 instance.mode
    # @config-detail instance.mode | string | `local` | `hosted` enables fail-closed startup, reload, and dispatch checks for permission, network, credential, Remote Control, local-pane, and REPL isolation. Current production backends remain ineligible until #5701. Read once at daemon start; change it with a restart. |
    field(:mode, :string, default: "local")

    # @config-reference config-configuration-00 instance.id
    # @config-detail instance.id | string | host and state directory | Stable id used by the shared multi-instance coordination store; read once at boot. Set `AIUR_LEASE_DATABASE_URL` to the same TLS PostgreSQL URL on each instance to enable shared ticket claims, repository leader election, and live-instance heartbeats. Remote certificates must chain to system CA roots; configured-store failures block new dispatch and live-instance reads. |
    field(:id, :string)

    # @config-reference config-configuration-00 instance.role
    # @config-detail instance.role | string | `primary` | `secondary` never claims the repository leader lease; `primary` is eligible to lead on equal terms with other eligible instances when `AIUR_LEASE_DATABASE_URL` is configured. Only the lease holder runs repository-wide landing, quarantine, merge-queue, and main-branch work. Label heals remain scoped to each instance's tracker view. Without a shared store, primary retains single-instance behavior. Read once at daemon start; change it with a restart. |
    field(:role, :string, default: "primary")

    embeds_one(:ignore, Aiur.Config.Schema.Instance.Ignore,
      on_replace: :update,
      defaults_to_struct: true
    )
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:mode, :role, :id], empty_values: [])
    |> validate_inclusion(:mode, ["local", "hosted"])
    |> validate_inclusion(:role, ["primary", "secondary"])
    |> validate_length(:id, min: 1, max: 200)
    |> cast_embed(:ignore, with: &Ignore.changeset/2)
  end
end
