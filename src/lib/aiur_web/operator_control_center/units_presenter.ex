defmodule AiurWeb.OperatorControlCenter.UnitsPresenter do
  @moduledoc """
  Loads and presents the DASH-016 Units catalog without owning lifecycle policy.

  Provider reads happen in `load/2`; projection, selection changes, tokens, and
  lookup remain pure so LiveView rendering never reaches a provider.
  """

  import AiurWeb.OperatorControlCenter.UnitsPresenter.Catalog, only: [catalog_status: 1, catalog_message: 3]

  alias Aiur.{CurrentRunMembership, TicketActivity, TrackerIdentity}
  alias Aiur.Projections.{UnitsPolicy, UnitsRow}
  alias Aiur.Projections.UnitsRow.Sources
  alias AiurWeb.OperatorControlCenter.RowToken

  @startup_loading_timeout_ms 600_000

  @type catalog_status :: :ready | :empty | :stale | :unavailable | :loading

  @spec load(map(), keyword()) :: map()
  def load(payload, opts \\ [])

  def load(payload, opts) when is_map(payload) do
    membership =
      safe_source(
        Keyword.get(opts, :membership_fun, &CurrentRunMembership.snapshot/0),
        unavailable_membership(),
        &valid_membership?/1
      )

    activity =
      safe_source(
        Keyword.get(opts, :activity_fun, &TicketActivity.snapshots/0),
        unavailable_activity(),
        &valid_activity?/1
      )
      |> Map.put_new(:health, :healthy)
      |> Map.put_new(:freshness, %{status: :fresh})

    status = status_source(payload)

    snapshot =
      UnitsRow.snapshot(%{
        membership: membership,
        status: status,
        activity: activity,
        decisions: decision_source(payload),
        issue_facts: issue_source(status)
      })

    startup_elapsed_ms = Map.get(payload, :startup_elapsed_ms, Aiur.Boot.elapsed_ms())

    status =
      cond do
        Map.get(payload, :daemon_starting?) == true and startup_elapsed_ms < @startup_loading_timeout_ms -> :loading
        Map.get(payload, :daemon_starting?) == true -> :unavailable
        true -> catalog_status(snapshot)
      end

    %{
      status: status,
      message: catalog_message(status, membership, snapshot),
      truncated?: snapshot.truncated?,
      snapshot: snapshot
    }
  end

  def load(_payload, _opts), do: load(%{})

  @doc false
  @spec starting_catalog() :: map()
  def starting_catalog do
    %{status: :loading, message: "The daemon is starting.", truncated?: false, snapshot: %{rows: [], truncated?: false}}
  end

  @doc false
  @spec starting_catalog(map()) :: map()
  def starting_catalog(%{units: %{} = units} = payload) do
    Map.put(payload, :units, Map.merge(units, %{status: :loading, message: "The daemon is starting."}))
  end

  def starting_catalog(payload) when is_map(payload), do: Map.put(payload, :units, starting_catalog())

  @spec project(map(), UnitsPolicy.selection() | term()) :: map()
  def project(%{snapshot: %{rows: rows}} = catalog, selection) when is_list(rows) do
    selection = UnitsPolicy.normalize_selection(selection)
    visible_rows = UnitsPolicy.filter(rows, selection)
    count_status = count_status(catalog)
    counts = display_counts(rows, selection, count_status)

    catalog
    |> Map.put(:selection, selection)
    |> Map.put(:rows, visible_rows)
    |> Map.put(:counts, counts)
    |> Map.put(:count_status, count_status)
    |> Map.put(:total_count, display_total(rows, count_status))
    |> Map.put(:revision, catalog_revision(catalog))
    |> Map.put(:zero_result?, zero_result?(rows, visible_rows, selection))
  end

  def project(_catalog, selection) do
    project(%{status: :unavailable, message: "Fleet data is unavailable.", snapshot: %{rows: []}}, selection)
  end

  @spec select_scope(UnitsPolicy.selection() | term(), atom() | String.t()) :: UnitsPolicy.selection()
  def select_scope(selection, scope) do
    selection = UnitsPolicy.normalize_selection(selection)
    UnitsPolicy.normalize_selection(%{selection | scope: scope})
  end

  @spec toggle_condition(UnitsPolicy.selection() | term(), atom() | String.t()) :: UnitsPolicy.selection()
  def toggle_condition(selection, condition) do
    selection = UnitsPolicy.normalize_selection(selection)

    case normalize_condition(condition) do
      nil ->
        selection

      condition ->
        conditions =
          if UnitsPolicy.selected?(selection, condition) do
            List.delete(selection.conditions, condition)
          else
            [condition | selection.conditions]
          end

        UnitsPolicy.normalize_selection(%{selection | conditions: conditions})
    end
  end

  @doc "Selects every filter exposed before the Units filter-bar divider."
  @spec select_all_filters() :: UnitsPolicy.selection()
  def select_all_filters do
    UnitsPolicy.normalize_selection(%{
      scope: :unfinished,
      conditions: UnitsPolicy.visible_conditions()
    })
  end

  @doc "Clears every visible Units filter."
  @spec select_no_filters() :: UnitsPolicy.selection()
  def select_no_filters, do: UnitsPolicy.normalize_selection(%{scope: :none, conditions: []})

  @spec row_token(map()) :: String.t() | nil
  def row_token(%{identity: %TrackerIdentity{} = identity}), do: RowToken.for(identity)
  def row_token(_row), do: nil

  @spec lookup(map(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup(%{snapshot: %{rows: rows}}, token) when is_list(rows) and is_binary(token) do
    case Enum.find(rows, &(row_token(&1) == token)) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  def lookup(_catalog, _token), do: {:error, :not_found}

  @doc "Returns the bounded, production live-region summary for one projected catalog."
  @spec announcement(map()) :: String.t()
  def announcement(view) when is_map(view) do
    visible = view |> Map.get(:rows, []) |> length()
    total = Map.get(view, :total_count)
    revision = Map.get(view, :revision, "unknown")

    summary =
      case Map.get(view, :status, :loading) do
        :loading -> "Loading Units."
        :unavailable -> "No live units."
        :empty -> "No units in this run yet."
        _status -> "Showing #{count_phrase(visible, total, view)}."
      end

    summary <> " Update #{revision}."
  end

  def announcement(_view), do: "No live units. Update unknown."

  defp valid_membership?(%{members: members}) when is_list(members), do: true
  defp valid_membership?(_membership), do: false

  defp valid_activity?(%{entries: entries}) when is_list(entries), do: true
  defp valid_activity?(_activity), do: false

  defp safe_source(fun, fallback, validator) when is_function(fun, 0) do
    value = fun.()
    if validator.(value), do: value, else: fallback
  rescue
    _error -> fallback
  catch
    _kind, _reason -> fallback
  end

  defp safe_source(_fun, fallback, _validator), do: fallback

  defp unavailable_membership do
    %{
      generation: nil,
      health: {:unavailable, :membership_provider_unavailable},
      health_message: "Fleet data is unavailable.",
      freshness: %{status: :unavailable},
      members: [],
      truncated?: false
    }
  end

  defp unavailable_activity do
    %{
      generation: nil,
      health: {:unavailable, :activity_provider_unavailable},
      freshness: %{status: :unavailable},
      entries: []
    }
  end

  defp status_source(payload) do
    payload
    |> presenter_status_source()
    |> enrich_internal_usage_fields(Map.get(payload, :units_status_snapshot))
  end

  defp enrich_internal_usage_fields(status, %{running: internal_running}) when is_list(internal_running) do
    internal_by_identity =
      Enum.reduce(internal_running, %{}, fn internal_row, rows ->
        case Sources.identity(internal_row) do
          %TrackerIdentity{} = identity -> Map.put(rows, Sources.key(identity), internal_row)
          _identity -> rows
        end
      end)

    running = Enum.map(status.running, &enrich_public_running_row(&1, internal_by_identity))

    Map.put(status, :running, running)
  end

  defp enrich_internal_usage_fields(status, _snapshot), do: status

  defp enrich_public_running_row(public_row, internal_by_identity) do
    with %TrackerIdentity{} = identity <- Sources.identity(public_row),
         internal_row when not is_nil(internal_row) <- Map.get(internal_by_identity, Sources.key(identity)) do
      public_row
      |> Map.put(:telemetry_attempt_id, Map.get(internal_row, :telemetry_attempt_id))
      |> Map.put(:usage_limit_reset_at, Map.get(internal_row, :usage_limit_reset_at))
      |> Map.put(:context_usage, public_context_usage(Map.get(internal_row, :context_usage)))
      |> Map.put(:turn_count, Map.get(internal_row, :turn_count))
      |> Map.put(:turn_count_observed?, Map.get(internal_row, :turn_count_observed?) == true)
    else
      _missing_identity_or_snapshot -> public_row
    end
  end

  defp public_context_usage(%{used_tokens: used} = context) when is_integer(used) and used >= 0 do
    Map.take(context, [:used_tokens, :window_tokens, :used_percent, :pressure])
  end

  defp public_context_usage(_context), do: nil

  defp presenter_status_source(payload) do
    fleet = Map.get(payload, :fleet, %{})
    health = source_health(payload, :fleet, fleet)

    %{
      generation: Map.get(payload, :generated_at),
      health: health,
      freshness: fleet_source_freshness(payload, fleet),
      running: safe_rows(fleet, :running),
      retrying: safe_rows(fleet, :retrying),
      idle: safe_rows(fleet, :idle)
    }
  end

  defp issue_source(status) do
    %{
      generation: status.generation,
      health: status.health,
      freshness: status.freshness,
      entries: status.running ++ status.retrying ++ status.idle
    }
  end

  defp decision_source(payload) do
    %{
      generation: Map.get(payload, :generated_at),
      health: decision_count_health(payload),
      freshness: source_freshness(payload),
      entries: []
    }
  end

  # The dashboard payload contains only the priority-bounded newest-50
  # Decision overview, so it cannot supply an exact per-ticket count. Keep the
  # DASH-016 source explicit and let its StatusReport fallback provide the
  # authoritative count for current rows; missing counts remain unknown.
  defp decision_count_health(payload) do
    case source_health(payload, :decisions, %{}) do
      :unavailable -> {:unavailable, :decision_counts_unavailable}
      _bounded_overview -> {:degraded, :bounded_decision_overview}
    end
  end

  defp source_health(payload, name, source) do
    cond do
      is_map(source) and is_map(Map.get(source, :error)) -> :unavailable
      get_in(payload, [:provider_health, name]) in [:ok, :available] -> :available
      get_in(payload, [:provider_health, name]) == :degraded -> :degraded
      true -> :unavailable
    end
  end

  defp source_freshness(payload) do
    case Map.get(payload, :generated_at) do
      generated_at when is_binary(generated_at) -> %{status: :fresh, observed_at: generated_at}
      _generated_at -> %{status: :unknown}
    end
  end

  defp fleet_source_freshness(_payload, %{snapshot_freshness: %{status: status} = freshness}) when status in [:current, :stale] do
    %{status: if(status == :current, do: :fresh, else: :stale), observed_at: Map.get(freshness, :observed_at), age_seconds: Map.get(freshness, :age_seconds)}
  end

  defp fleet_source_freshness(payload, _fleet), do: source_freshness(payload)

  defp safe_rows(fleet, bucket) when is_map(fleet) do
    case Map.get(fleet, bucket) do
      rows when is_list(rows) -> rows
      _rows -> []
    end
  end

  defp safe_rows(_fleet, _bucket), do: []

  defp count_status(%{status: :loading}), do: :loading
  defp count_status(%{status: :unavailable}), do: :unavailable
  defp count_status(%{status: :stale}), do: :partial
  defp count_status(%{truncated?: true}), do: :partial
  defp count_status(%{snapshot: %{truncated?: true}}), do: :partial
  defp count_status(_catalog), do: :exact

  defp display_counts(_rows, _selection, count_status) when count_status in [:unavailable, :loading] do
    [:scope | UnitsPolicy.conditions()]
    |> Map.new(&{&1, nil})
  end

  defp display_counts(rows, selection, _count_status), do: UnitsPolicy.counts(rows, selection)

  defp display_total(_rows, :unavailable), do: nil
  defp display_total(_rows, :loading), do: nil
  defp display_total(rows, _count_status), do: length(rows)

  defp catalog_revision(catalog) do
    snapshot = Map.get(catalog, :snapshot, %{})

    %{
      status: Map.get(catalog, :status),
      message: Map.get(catalog, :message),
      truncated?: Map.get(catalog, :truncated?, Map.get(snapshot, :truncated?, false)),
      health: Map.get(snapshot, :health),
      rows: snapshot |> Map.get(:rows, []) |> Enum.map(&announcement_row_signature/1)
    }
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 5)
    |> Base.encode16(case: :lower)
  rescue
    _error -> "unknown"
  end

  defp announcement_row_signature(row) do
    %{
      facts:
        Map.take(row, [
          :identity,
          :title,
          :lifecycle,
          :terminal?,
          :replacement_boundary?,
          :tracker_state,
          :backend,
          :agent_family,
          :requested_model,
          :resolved_model,
          :effort,
          :account,
          :complexity,
          :build_lane,
          :reasons,
          :open_command_count,
          :progress,
          :latest_evidence,
          :provider_health
        ]),
      runtime:
        row
        |> Map.get(:runtime, %{})
        |> Map.take([:bucket, :work_state, :waiting_reason, :tracker_paused?, :membership_lifecycle])
    }
  end

  defp count_phrase(visible, total, %{count_status: :partial}) when is_integer(total),
    do: "at least #{visible} of at least #{total} Units"

  defp count_phrase(visible, total, _view) when is_integer(total),
    do: "#{visible} of #{total} Units"

  defp count_phrase(_visible, _total, _view), do: "an unavailable number of Units"

  defp zero_result?([], _visible_rows, _selection), do: false

  defp zero_result?(_rows, [], selection),
    do: selection != UnitsPolicy.normalize_selection(UnitsPolicy.default_selection())

  defp zero_result?(_rows, _visible_rows, _selection), do: false

  defp normalize_condition(condition) when condition in [:active, :alert, :paused, :stuck, :queued, :finished], do: condition

  defp normalize_condition(condition) when is_binary(condition) do
    Enum.find(UnitsPolicy.conditions(), &(Atom.to_string(&1) == String.downcase(String.trim(condition))))
  end

  defp normalize_condition(_condition), do: nil
end
