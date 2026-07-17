defmodule AiurWeb.OperatorControlCenter.UnitsPresenter do
  @moduledoc """
  Loads and presents the DASH-016 Units catalog without owning lifecycle policy.

  Provider reads happen in `load/2`; projection, selection changes, tokens, and
  lookup remain pure so LiveView rendering never reaches a provider.
  """

  alias Aiur.{CurrentRunMembership, TicketActivity, TrackerIdentity}
  alias AiurWeb.OperatorControlCenter.{UnitsPolicy, UnitsRow}

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
      message: catalog_message(status, membership),
      snapshot: snapshot
    }
  end

  def load(_payload, _opts), do: load(%{})

  @spec project(map(), UnitsPolicy.selection() | term()) :: map()
  def project(%{snapshot: %{rows: rows}} = catalog, selection) when is_list(rows) do
    selection = UnitsPolicy.normalize_selection(selection)
    visible_rows = UnitsPolicy.filter(rows, selection)
    counts = UnitsPolicy.counts(rows, selection)

    catalog
    |> Map.put(:selection, selection)
    |> Map.put(:rows, visible_rows)
    |> Map.put(:counts, counts)
    |> Map.put(:total_count, length(rows))
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
      freshness: source_freshness(payload),
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

  defp safe_rows(fleet, bucket) when is_map(fleet) do
    case Map.get(fleet, bucket) do
      rows when is_list(rows) -> rows
      _rows -> []
    end
  end

  defp safe_rows(_fleet, _bucket), do: []

  defp catalog_status(%{health: %{membership: :unavailable}}), do: :unavailable
  defp catalog_status(%{health: %{membership: :degraded}}), do: :stale

  defp catalog_status(%{health: %{membership: status}, rows: []})
       when status not in [:healthy, :available],
       do: :unavailable

  defp catalog_status(%{health: %{membership: status}})
       when status not in [:healthy, :available],
       do: :stale

  defp catalog_status(%{freshness: %{membership: %{status: status}}}) when status in [:stale, :unknown, :unavailable],
    do: :stale

  defp catalog_status(%{rows: []}), do: :empty
  defp catalog_status(_snapshot), do: :ready

  defp catalog_message(:ready, _membership), do: nil
  defp catalog_message(:empty, _membership), do: "No units have been observed in this run."

  defp catalog_message(:stale, membership),
    do: Map.get(membership, :health_message) || "Units are showing the last-known current-run membership."

  defp catalog_message(:unavailable, membership),
    do: Map.get(membership, :health_message) || "Units catalog is unavailable."

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
