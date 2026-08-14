defmodule Aiur.Config.Schema.BuildOrder do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field(:ticket_detail_freshness_ms, :integer, default: 30_000)
    field(:ticket_detail_max_entries, :integer, default: 32)
    field(:ticket_detail_max_description_bytes, :integer, default: 16_384)
    field(:ticket_history_limit, :integer, default: 50)
    field(:ticket_history_max_identities, :integer, default: 100)
    field(:ticket_history_stale_after_ms, :integer, default: 60_000)
    field(:graph_catalog_refresh_ms, :integer, default: 60_000)
    field(:graph_catalog_labels_refresh_ms, :integer, default: 600_000)
    field(:graph_selected_refresh_ms, :integer, default: 15_000)
    field(:graph_demand_refresh_ms, :integer, default: 5_000)
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
        :graph_selected_refresh_ms,
        :graph_demand_refresh_ms,
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
    |> validate_number(:graph_selected_refresh_ms, greater_than: 0, less_than_or_equal_to: 300_000)
    |> validate_number(:graph_demand_refresh_ms, greater_than: 0, less_than_or_equal_to: 300_000)
    |> validate_number(:graph_refresh_timeout_ms, greater_than: 0, less_than_or_equal_to: 120_000)
    |> validate_number(:graph_max_selected_roots, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:graph_max_inflight, greater_than: 0, less_than_or_equal_to: 16)
    |> validate_demand_threshold()
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

  defp validate_demand_threshold(changeset) do
    selected = get_field(changeset, :graph_selected_refresh_ms)
    demand = get_field(changeset, :graph_demand_refresh_ms)

    if is_integer(selected) and is_integer(demand) and demand > selected do
      add_error(changeset, :graph_demand_refresh_ms, "must not exceed graph_selected_refresh_ms")
    else
      changeset
    end
  end
end
