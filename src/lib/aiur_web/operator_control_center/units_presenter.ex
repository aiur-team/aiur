defmodule AiurWeb.OperatorControlCenter.UnitsPresenter do
  @moduledoc """
  Loads and presents the DASH-016 Units catalog without owning lifecycle policy.

  Provider reads happen in `load/2`; projection, selection changes, tokens, and
  lookup remain pure so LiveView rendering never reaches a provider.
  """

  alias Aiur.{CurrentRunMembership, TicketActivity, TrackerIdentity}
  alias AiurWeb.OperatorControlCenter.{UnitsPolicy, UnitsPresentation, UnitsRow}

  @type catalog_status :: :ready | :empty | :stale | :unavailable

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

    status = catalog_status(snapshot)

    %{
      status: status,
      message: catalog_message(status, membership, snapshot),
      truncated?: snapshot.truncated?,
      snapshot: snapshot
    }
  end

  def load(_payload, _opts), do: load(%{})

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
    project(%{status: :unavailable, message: "Units catalog is unavailable.", snapshot: %{rows: []}}, selection)
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
  def row_token(%{identity: %TrackerIdentity{} = identity}) do
    case TrackerIdentity.github_key(identity) do
      nil -> nil
      key -> key |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1)) |> Base.url_encode64(padding: false)
    end
  end

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
        :unavailable -> "Units catalog unavailable."
        :empty -> "No units have been observed in this run."
        :stale -> "Showing #{count_phrase(visible, total, view)} from stale catalog data."
        _status -> "Showing #{count_phrase(visible, total, view)}."
      end

    summary <> " Catalog update #{revision}."
  end

  def announcement(_view), do: "Units catalog unavailable. Catalog update unknown."

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
      health_message: "current-run membership is unavailable",
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

  defp catalog_status(%{health: %{membership: :unavailable}, rows: []}), do: :unavailable
  defp catalog_status(%{health: %{membership: :unavailable}}), do: :stale
  defp catalog_status(%{health: %{membership: :degraded}}), do: :stale

  defp catalog_status(%{health: %{membership: status}, rows: []})
       when status not in [:healthy, :available],
       do: :unavailable

  defp catalog_status(%{health: %{membership: status}})
       when status not in [:healthy, :available],
       do: :stale

  defp catalog_status(%{freshness: %{membership: %{status: status}}}) when status in [:stale, :unknown, :unavailable],
    do: :stale

  # A degraded fleet source must be visible on the catalog itself: a stale
  # `Active 0` and a current `Active 0` mean different things, so the catalog
  # is never presented as ready while the fleet view behind it is last-known-good.
  defp catalog_status(%{rows: []} = snapshot), do: if(fleet_view_degraded?(snapshot), do: :stale, else: :empty)
  defp catalog_status(snapshot), do: if(fleet_view_degraded?(snapshot), do: :stale, else: :ready)

  defp fleet_view_degraded?(snapshot) do
    fleet_health(snapshot) not in [:healthy, :available] or
      fleet_freshness_status(snapshot) in [:stale, :unknown, :unavailable]
  end

  defp fleet_health(snapshot), do: snapshot |> Map.get(:health, %{}) |> Map.get(:status, :unknown)

  defp fleet_freshness_status(snapshot) do
    case snapshot |> Map.get(:freshness, %{}) |> Map.get(:status) do
      %{status: status} -> status
      status when is_atom(status) -> status
      _freshness -> :unknown
    end
  end

  defp fleet_age_seconds(snapshot) do
    case snapshot |> Map.get(:freshness, %{}) |> Map.get(:status) do
      %{age_seconds: age_seconds} when is_integer(age_seconds) and age_seconds >= 0 -> age_seconds
      _freshness -> nil
    end
  end

  defp catalog_message(:ready, _membership, _snapshot), do: nil
  defp catalog_message(:empty, _membership, _snapshot), do: "No units have been observed in this run."

  # Never quote a healthy membership as the reason for a stale catalog: the
  # cause is whichever source is actually degraded.
  defp catalog_message(:stale, membership, snapshot),
    do: membership_fault(membership) || stale_source_message(snapshot)

  defp catalog_message(:unavailable, membership, _snapshot),
    do: membership_fault(membership) || "Units catalog is unavailable."

  defp membership_fault(membership) do
    case Map.get(membership, :health) do
      health when health in [:healthy, :available] -> nil
      _degraded_or_unknown -> Map.get(membership, :health_message)
    end
  end

  defp stale_source_message(snapshot) do
    lead = stale_lead(snapshot)

    cond do
      fleet_health(snapshot) not in [:healthy, :available] ->
        "#{lead} while the fleet snapshot is unavailable."

      fleet_freshness_status(snapshot) in [:stale, :unknown, :unavailable] ->
        "#{lead} while fleet snapshot refresh is degraded." <> fleet_age_phrase(snapshot)

      true ->
        "#{lead} while current-run membership reconciles."
    end
  end

  # "Showing the last-known-good catalog" is only true when something is
  # retained to show. With no rows the same sentence over an empty table is the
  # confident-wrong-claim shape this module exists to remove.
  defp stale_lead(%{rows: []}), do: "No last-known-good Units catalog is retained"
  defp stale_lead(_snapshot), do: "Showing the last-known-good Units catalog"

  defp fleet_age_phrase(snapshot) do
    case fleet_age_seconds(snapshot) do
      nil -> ""
      age_seconds -> " Fleet view is #{UnitsPresentation.age_label(age_seconds)} old."
    end
  end

  defp count_status(%{status: :unavailable}), do: :unavailable
  defp count_status(%{status: :stale}), do: :partial
  defp count_status(%{truncated?: true}), do: :partial
  defp count_status(%{snapshot: %{truncated?: true}}), do: :partial
  defp count_status(_catalog), do: :exact

  defp display_counts(_rows, _selection, :unavailable) do
    [:scope | UnitsPolicy.conditions()]
    |> Map.new(&{&1, nil})
  end

  defp display_counts(rows, selection, _count_status), do: UnitsPolicy.counts(rows, selection)

  defp display_total(_rows, :unavailable), do: nil
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
