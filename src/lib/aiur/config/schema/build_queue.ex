defmodule Aiur.Config.Schema.BuildQueue do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    # @config-reference config-configuration-21 build_queue.set_order
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail build_queue.set_order | string | `none` | `none` preserves ordinary candidate ordering. Opt into `ranked` to prefer queue sets by persisted rank (creation order by default); ready members follow list position, while optimistic members retain deepest-first ordering within each set. Ready work always precedes optimistic work. With a cap or reserve configured, earlier unknown or stale readiness blocks ranked spill because it may have ready work. Held sets remain stopped. Main CI fixer tickets dispatch ahead of ranked sets. |
    field(:set_order, :string, default: "none")
    # @config-reference config-configuration-21 build_queue.max_active_sets
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail build_queue.max_active_sets | integer or null | nil | Maximum sets with started, unfinished members (including CI/review waits); minimum 1. Null lets capacity decide. Held sets do not consume this cap; existing runners are never preempted. |
    field(:max_active_sets, :integer, default: nil)
    # @config-reference config-configuration-21 build_queue.spill_reserve_slots
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail build_queue.spill_reserve_slots | integer | 0 | Slots kept free for the earliest unfinished, unheld set before admitting later-set work; minimum 0. Reserve applies even while that set waits on review. Set-policy waits appear as `queue_set_order` in status and queue show. |
    field(:spill_reserve_slots, :integer, default: 0)
    # @config-reference config-configuration-21 build_queue.enabled
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail build_queue.enabled | boolean | true | Enable build queue reconciliation. The server maintains dispatch hints, promotes ready items, and withdraws todo from unclaimed items whose prerequisites change. Disabling the queue removes its server and hints table on the next run. |
    field(:enabled, :boolean, default: true)
    # @config-reference config-configuration-21 build_queue.start_trigger
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail build_queue.start_trigger | string | `pr_merged` | Prerequisite stage needed for queue promotion: `issue_closed`, `pr_merged`, `pr_approved`, `pr_ci_green`, or `pr_opened`. Also governs native dependency dispatch. Override with `queue add --start-on` or `queue set NAME --start-on`; `default` follows config. Missing or stale evidence never releases dependents. Optimistic stages combine lifecycle labels with retained per-PR progress. `pr_approved` adds one conditional review read per watched blocker. Linear dependency dispatch supports only `issue_closed` and `pr_merged`. See [Start trigger](/concepts/build-orders#start-trigger). |
    field(:start_trigger, :string, default: "pr_merged")
    # @config-reference config-configuration-21 build_queue.optimistic_slot_share
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail build_queue.optimistic_slot_share | float | 0.5 | Fleet-wide optimistic share, 0..1. Zero disables optimistic dispatch; otherwise the cap is max(1, floor(share × effective agent limit)). Ready work starts first; merged blockers free share on the next cycle. Running agents are never preempted. |
    field(:optimistic_slot_share, :float, default: 0.5)
    # @config-reference config-configuration-21 build_queue.reconcile_interval_seconds
    # @config-detail build_queue.reconcile_interval_seconds | integer | 60 | Reconciliation interval in seconds; 10..3600. |
    field(:reconcile_interval_seconds, :integer, default: 60)
    # @config-reference config-configuration-21 build_queue.max_writes_per_minute
    # @config-detail build_queue.max_writes_per_minute | integer | 20 | Queue write budget per minute; 1..60. |
    field(:max_writes_per_minute, :integer, default: 20)
    # @config-reference config-configuration-21 build_queue.observation_max_age_seconds
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail build_queue.observation_max_age_seconds | integer or null | derived (2× polling.interval_seconds) | Maximum observation age in seconds; null derives twice the base poll interval (240 seconds by default); explicit values must be 10..3600. A non-empty queue whose open-issue snapshot is older than this lists open issues itself, at most once per this age. |
    field(:observation_max_age_seconds, :integer, default: nil)
    # @config-reference config-configuration-21 build_queue.merged_open_grace_seconds
    # @config-detail build_queue.merged_open_grace_seconds | integer | 600 | Grace period in seconds for an `issue_closed` queue prerequisite whose PR merged but issue remains open; 60..86400. |
    field(:merged_open_grace_seconds, :integer, default: 600)
    # @config-reference config-configuration-21 build_queue.optimistic_failure_grace_seconds
    # @config-detail build_queue.optimistic_failure_grace_seconds | integer | 600 | Seconds to wait for a reopened or replacement blocker PR before parking optimistic dependents; 60..86400. |
    field(:optimistic_failure_grace_seconds, :integer, default: 600)
    # @config-reference config-configuration-21 build_queue.optimistic_churn_attention_threshold
    # @config-detail build_queue.optimistic_churn_attention_threshold | integer | 3 | Conflicting integrations before an informational attention; 0 disables, 0..50. Never pauses work. |
    field(:optimistic_churn_attention_threshold, :integer, default: 3)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :set_order,
        :max_active_sets,
        :spill_reserve_slots,
        :optimistic_slot_share,
        :start_trigger,
        :enabled,
        :reconcile_interval_seconds,
        :max_writes_per_minute,
        :observation_max_age_seconds,
        :merged_open_grace_seconds,
        :optimistic_failure_grace_seconds,
        :optimistic_churn_attention_threshold
      ],
      empty_values: []
    )
    |> validate_inclusion(:start_trigger, Enum.map(Aiur.StartTrigger.triggers(), &Atom.to_string/1), message: "must be one of: #{Enum.join(Aiur.StartTrigger.triggers(), ", ")}")
    |> validate_required([:start_trigger, :optimistic_slot_share, :set_order, :spill_reserve_slots])
    |> validate_inclusion(:set_order, ["ranked", "none"])
    |> validate_number(:max_active_sets, greater_than_or_equal_to: 1)
    |> validate_number(:spill_reserve_slots, greater_than_or_equal_to: 0)
    |> validate_number(:optimistic_slot_share, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:reconcile_interval_seconds, greater_than_or_equal_to: 10, less_than_or_equal_to: 3600)
    |> validate_number(:max_writes_per_minute, greater_than_or_equal_to: 1, less_than_or_equal_to: 60)
    |> validate_number(:observation_max_age_seconds, greater_than_or_equal_to: 10, less_than_or_equal_to: 3600)
    |> validate_number(:optimistic_failure_grace_seconds, greater_than_or_equal_to: 60, less_than_or_equal_to: 86_400)
    |> validate_number(:optimistic_churn_attention_threshold, greater_than_or_equal_to: 0, less_than_or_equal_to: 50)
    |> validate_number(:merged_open_grace_seconds, greater_than_or_equal_to: 60, less_than_or_equal_to: 86_400)
  end
end
