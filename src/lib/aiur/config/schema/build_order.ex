defmodule Aiur.Config.Schema.BuildOrder do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Aiur.Config.Schema.GeneralEpic

  @default_epics [
    %{"key" => "bugs", "label" => "Bugs", "labels" => ["bug"], "hue" => 38, "icon" => "bug"},
    %{"key" => "design", "label" => "Design", "labels" => ["design"], "hue" => 312, "icon" => "pen"},
    %{"key" => "infra", "label" => "Infra", "labels" => ["refactor", "chore"], "hue" => 200, "icon" => "server"},
    %{"key" => "docs", "label" => "Docs", "labels" => ["documentation"], "hue" => 100, "icon" => "docs"}
  ]

  @primary_key false

  embedded_schema do
    # `nil` means "derive from the tracker poll interval" — see
    # `Aiur.BuildOrder.Cadence`. These three were constants chosen when the
    # tracker polled every 5 seconds; leaving them as constants is what let them
    # survive #2064 moving the tracker to 120 seconds. An explicit setting still
    # wins, so this removes a stale default rather than an operator's control.
    # @config-reference config-configuration-build-order-00 build_order.ticket_detail_freshness_ms
    # @config-detail build_order.ticket_detail_freshness_ms | integer | derived (¼ poll interval, min 5000) | Freshness window for ticket detail. |
    field(:ticket_detail_freshness_ms, :integer, default: nil)
    # @config-reference config-configuration-build-order-00 build_order.ticket_detail_max_entries
    # @config-detail build_order.ticket_detail_max_entries | integer | 32 | Maximum cached ticket-detail entries. |
    field(:ticket_detail_max_entries, :integer, default: 32)
    # @config-reference config-configuration-build-order-00 build_order.ticket_detail_max_description_bytes
    # @config-detail build_order.ticket_detail_max_description_bytes | integer | 16384 | Maximum cached ticket-description size. |
    field(:ticket_detail_max_description_bytes, :integer, default: 16_384)
    # @config-reference config-configuration-build-order-00 build_order.ticket_history_limit
    # @config-detail build_order.ticket_history_limit | integer | 50 | Maximum ticket history records per view. |
    field(:ticket_history_limit, :integer, default: 50)
    # @config-reference config-configuration-build-order-00 build_order.ticket_history_max_identities
    # @config-detail build_order.ticket_history_max_identities | integer | 100 | Maximum distinct ticket identities retained in history. |
    field(:ticket_history_max_identities, :integer, default: 100)
    # @config-reference config-configuration-build-order-00 build_order.ticket_history_stale_after_ms
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail build_order.ticket_history_stale_after_ms | integer | 60000 | Minimum age after which ticket history is stale. It is a floor, not the final window: the effective window is always at least two poll intervals wide, so a value below the poll cadence does not mark correct data stale. |
    field(:ticket_history_stale_after_ms, :integer, default: 60_000)
    # Failure-backoff and age-display base for the catalog snapshot. The catalog
    # is event-sourced from daemon-owned store state and does not refresh on this
    # cadence; `nil` means "derive from the tracker poll interval" (see
    # `Aiur.BuildOrder.Cadence`).
    # @config-reference config-configuration-build-order-00 build_order.graph_catalog_refresh_ms
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail build_order.graph_catalog_refresh_ms | integer | derived (1× effective poll interval) | Base cadence for the Build Order catalog's reads (boot, a viewer's mount, a degraded re-list) and the window after which a selected root is displayed as ageing. The catalog is event-sourced (#2325) and demand-gated (#2312): it is maintained from the resource store's change stream, so this is not a recurring poll, and no page open means no read. |
    field(:graph_catalog_refresh_ms, :integer, default: nil)
    # @config-reference config-configuration-build-order-00 build_order.graph_catalog_labels_refresh_ms
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail build_order.graph_catalog_labels_refresh_ms | integer | derived (5× effective poll interval, min 600000) | Cadence for the labelled catalog read that resolves epic and wave counts on a boot/mount/degraded read; the event-sourced catalog resolves those counts from the store instead. |
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
    # @config-reference config-configuration-build-order-00 build_order.graph_refresh_timeout_ms
    # @config-detail build_order.graph_refresh_timeout_ms | integer | 30000 | Maximum graph-refresh request duration. |
    field(:graph_refresh_timeout_ms, :integer, default: 30_000)
    # @config-reference config-configuration-build-order-00 build_order.graph_max_selected_roots
    # @config-detail build_order.graph_max_selected_roots | integer | 32 | Maximum selected Build Order roots. |
    field(:graph_max_selected_roots, :integer, default: 32)
    # @config-reference config-configuration-build-order-00 build_order.graph_max_inflight
    # @config-detail build_order.graph_max_inflight | integer | 4 | Maximum concurrent graph refreshes. |
    field(:graph_max_inflight, :integer, default: 4)
    # @config-reference config-configuration-build-order-00 build_order.general_epics
    # @config-detail build_order.general_epics | array | Bugs, Design, Infra, Docs (below) | General epic definitions in column order. A list replaces the defaults; `[]` disables general epics. |
    embeds_many(:general_epics, GeneralEpic, on_replace: :delete)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    # Ecto forces embeds_many's struct default to [], so defaults go into attrs.
    attrs = Map.put_new(attrs, "general_epics", @default_epics)

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
    |> cast_embed(:general_epics, with: &GeneralEpic.changeset/2)
    |> validate_unique_epics()
  end

  defp validate_unique_epics(changeset) do
    case get_change(changeset, :general_epics) do
      children when is_list(children) ->
        if Enum.all?(children, & &1.valid?),
          do: check_unique_epics(changeset, Enum.map(children, &apply_changes/1)),
          else: changeset

      _no_change ->
        changeset
    end
  end

  defp check_unique_epics(changeset, epics) do
    duplicate_key = epics |> Enum.map(& &1.key) |> Enum.frequencies() |> Enum.find(fn {_key, count} -> count > 1 end)

    changeset =
      case duplicate_key do
        {key, _count} -> add_error(changeset, :general_epics, "key #{inspect(key)} is used by more than one epic")
        nil -> changeset
      end

    epics
    |> Enum.flat_map(fn epic -> Enum.map(epic.labels, &{&1, epic.key}) end)
    |> Enum.reduce_while({changeset, %{}}, fn {label, key}, {current, owners} ->
      case Map.fetch(owners, label) do
        {:ok, owner} ->
          {:halt, {add_error(current, :general_epics, "label #{inspect(label)} is in both #{owner} and #{key}; a label can place a ticket in one epic only"), owners}}

        :error ->
          {:cont, {current, Map.put(owners, label, key)}}
      end
    end)
    |> elem(0)
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
