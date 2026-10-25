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

    # Operator deployments use the owner's subscription credentials; consumer
    # deployments are restricted to API keys. Kept separate from `mode`, which
    # controls hosted execution isolation rather than billing identity.
    # @config-reference config-configuration-00 instance.deployment_kind
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail instance.deployment_kind | string | `operator` | Selects credential owner. Hosted operators may use subscriptions; consumers use API keys only. |
    field(:deployment_kind, :string, default: "operator")

    # @config-reference config-configuration-00 instance.id
    # @config-detail instance.id | string | host and state directory | Stable id used by the shared multi-instance coordination store; read once at boot. Set `AIUR_LEASE_DATABASE_URL` to the same TLS PostgreSQL URL on each instance to enable shared ticket claims, repository leader election, and live-instance heartbeats. Remote certificates must chain to system CA roots; configured-store failures block new dispatch and live-instance reads. |
    field(:id, :string)

    # @config-reference config-configuration-00 instance.owns
    # @config-detail instance.owns | array of maps | `[]` | Ticket rules reserved for this live instance. Each entry has exactly one `label` or positive `ticket`; matching rules apply only while this instance is dispatching. Requires the shared lease store to coordinate live instances. Hot-reloadable. |
    field(:owns, {:array, :map}, default: [])

    # @config-reference config-configuration-00 instance.pool
    # @config-detail instance.pool | boolean | `true` | Whether this instance may dispatch tickets that no live, dispatching instance reserves with `instance.owns`. Hot-reloadable. |
    field(:pool, :boolean, default: true)

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
    |> cast(attrs, [:mode, :deployment_kind, :role, :id, :owns, :pool], empty_values: [])
    |> validate_inclusion(:mode, ["local", "hosted"])
    |> validate_inclusion(:deployment_kind, ["operator", "consumer"])
    |> validate_inclusion(:role, ["primary", "secondary"])
    |> validate_length(:id, min: 1, max: 200)
    |> validate_owns()
    |> cast_embed(:ignore, with: &Ignore.changeset/2)
  end

  defp validate_owns(changeset) do
    validate_change(changeset, :owns, fn :owns, rules ->
      if Enum.all?(rules, &valid_ownership_rule?/1),
        do: [],
        else: [owns: "must contain maps with exactly one non-empty label or positive ticket"]
    end)
  end

  defp valid_ownership_rule?(%{"label" => label} = rule),
    do: map_size(rule) == 1 and is_binary(label) and String.trim(label) != ""

  defp valid_ownership_rule?(%{"ticket" => ticket} = rule),
    do: map_size(rule) == 1 and is_integer(ticket) and ticket > 0

  defp valid_ownership_rule?(%{label: label} = rule),
    do: map_size(rule) == 1 and is_binary(label) and String.trim(label) != ""

  defp valid_ownership_rule?(%{ticket: ticket} = rule),
    do: map_size(rule) == 1 and is_integer(ticket) and ticket > 0

  defp valid_ownership_rule?(_), do: false
end
