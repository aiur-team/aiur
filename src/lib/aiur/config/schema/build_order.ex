defmodule Aiur.Config.Schema.BuildOrder do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    # `nil` means "derive from the tracker poll interval" — see
    # `Aiur.BuildOrder.Cadence`. These three were constants chosen when the
    # tracker polled every 5 seconds; leaving them as constants is what let them
    # survive #2064 moving the tracker to 120 seconds. An explicit setting still
    # wins, so this removes a stale default rather than an operator's control.
    field(:ticket_detail_freshness_ms, :integer, default: nil)
    field(:ticket_detail_max_entries, :integer, default: 32)
    field(:ticket_detail_max_description_bytes, :integer, default: 16_384)
    field(:ticket_history_limit, :integer, default: 50)
    field(:ticket_history_max_identities, :integer, default: 100)
    field(:ticket_history_stale_after_ms, :integer, default: 60_000)
    # The interval the catalog refresh runs on *while a Build Order page is
    # open*. Since #2312 the catalog is demand-gated: no page open, no refresh,
    # so this is a bound on the open page's freshness, not a background cadence.
    field(:graph_catalog_refresh_ms, :integer, default: nil)
    field(:graph_catalog_labels_refresh_ms, :integer, default: nil)
    # `graph_selected_refresh_ms` and `graph_demand_refresh_ms` are gone. They
    # were the two settings that let *viewing* buy GitHub reads — one repeating
    # for as long as a page stayed open, one firing on selection — and there is
    # no value either could take that makes that correct, so they are removed
    # rather than retuned. A selected root is now read when a writer or an
    # explicit refresh asks for it.
    #
    # A configuration that still sets them keeps loading: `cast/3` ignores keys
    # outside the permitted list, so an operator upgrading gets the new behaviour
    # and not a boot failure.
    field(:graph_refresh_timeout_ms, :integer, default: 30_000)
    field(:graph_max_selected_roots, :integer, default: 32)
    field(:graph_max_inflight, :integer, default: 4)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :ticket_detail_freshness_ms,
        :ticket_detail_max_entries,
        :ticket_detail_max_description_bytes,
        :ticket_history_limit,
        :ticket_history_max_identities,
        :ticket_history_stale_after_ms,
        :graph_catalog_refresh_ms,
        :graph_catalog_labels_refresh_ms,
        :graph_refresh_timeout_ms,
        :graph_max_selected_roots,
        :graph_max_inflight
      ],
      empty_values: []
    )
    |> validate_number(:ticket_detail_freshness_ms, greater_than: 0, less_than_or_equal_to: 300_000)
    |> validate_number(:ticket_detail_max_entries, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:ticket_detail_max_description_bytes, greater_than: 0, less_than_or_equal_to: 16_384)
    |> validate_number(:ticket_history_limit, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:ticket_history_max_identities, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:ticket_history_stale_after_ms, greater_than: 0, less_than_or_equal_to: 300_000)
    |> validate_number(:graph_catalog_refresh_ms, greater_than: 0, less_than_or_equal_to: 3_600_000)
    |> validate_number(:graph_catalog_labels_refresh_ms, greater_than: 0, less_than_or_equal_to: 3_600_000)
    |> validate_number(:graph_refresh_timeout_ms, greater_than: 0, less_than_or_equal_to: 120_000)
    |> validate_number(:graph_max_selected_roots, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:graph_max_inflight, greater_than: 0, less_than_or_equal_to: 16)
    |> validate_labels_cadence()
  end

  # The per-member label read costs roughly 26 GraphQL points per page against a
  # 5000-points/hour budget, versus 1 without it (#1766). A labels cadence faster
  # than the catalog poll would make every poll buy it, so the configuration is
  # rejected rather than silently spending the budget.
  defp validate_labels_cadence(changeset) do
    catalog = get_field(changeset, :graph_catalog_refresh_ms)
    labels = get_field(changeset, :graph_catalog_labels_refresh_ms)

    if is_integer(catalog) and is_integer(labels) and labels < catalog do
      add_error(changeset, :graph_catalog_labels_refresh_ms, "must not be less than graph_catalog_refresh_ms")
    else
      changeset
    end
  end
end
