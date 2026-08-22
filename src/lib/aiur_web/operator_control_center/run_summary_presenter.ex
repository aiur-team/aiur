defmodule AiurWeb.OperatorControlCenter.RunSummaryPresenter do
  @moduledoc """
  Formats the DASH-014 `Aiur.CurrentRunSummary` snapshot into a named,
  screen-reader-friendly view for the Units page current-run summary.

  This presenter performs no aggregate math: every count, weight, progress
  fraction, elapsed value, and ETA comes straight from the daemon-owned
  snapshot. It only formats and names those facts and keeps the distinct
  states (unknown, partial coverage, stale, unavailable, zero, exact)
  visibly separate.

  ## Last-known-good retention

  `reconcile/2` decides which snapshot to display. A newly-received
  unavailable snapshot never replaces a healthy same-run summary with zeros:
  it retains the prior same-run snapshot labelled stale. A new run generation
  or an unconfirmable run window shows the unavailable snapshot rather than
  presenting the prior run as current.
  """

  @type snapshot :: map()
  @type view :: map()

  @doc """
  Given the snapshot currently displayed (`current`, may be `nil`) and an
  `incoming` snapshot, return `{source, retained?}` where `source` is the
  snapshot to present and `retained?` is true when `source` is a stale
  last-known-good retained across an unavailable update.

  An available incoming snapshot is always adopted. An unavailable incoming
  snapshot retains `current` only when `current` is a healthy same-run
  summary; otherwise the unavailable snapshot is shown so a new run
  generation or an unconfirmable run window never presents the prior run as
  current.
  """
  @spec reconcile(snapshot() | nil, snapshot() | nil) :: {snapshot() | nil, boolean()}
  def reconcile(current, incoming) when is_map(incoming) do
    cond do
      available?(incoming) -> {incoming, false}
      is_map(current) and available?(current) and same_run?(current, incoming) -> {current, true}
      true -> {incoming, false}
    end
  end

  def reconcile(current, _incoming), do: {current, false}

  @doc """
  Present `source` (may be `nil`) as a named view. `retained?` marks a stale
  last-known-good. When a summary is retained across a failed refresh, the
  values come from `source` but health/freshness come from `status_source`
  (the incoming unavailable snapshot) so the labels report the failed refresh
  rather than the last-known-good's own freshness.
  """
  @spec present(snapshot() | nil, boolean(), snapshot() | nil) :: view()
  def present(source, retained? \\ false, status_source \\ nil)

  def present(source, retained?, status_source) when is_map(source) do
    run = Map.get(source, :run, %{})
    status = status_source || source
    progress = present_progress(Map.get(source, :progress, %{}), Map.get(source, :weights, %{}))

    %{
      state: state(source, retained?),
      retained?: retained?,
      generation: Map.get(source, :generation, 0),
      run_id: Map.get(run, :id),
      counts: present_counts(Map.get(source, :counts, %{})),
      progress: progress,
      elapsed: present_elapsed(run),
      eta: present_eta(Map.get(source, :eta, %{}), progress),
      health: present_health(Map.get(status, :health, %{})),
      freshness: present_freshness(Map.get(status, :freshness, %{}))
    }
  end

  def present(_source, _retained?, _status_source), do: %{state: :loading, retained?: false}

  @doc "A single bounded screen-reader announcement summarising the presented `view`."
  @spec announcement(view()) :: String.t()
  def announcement(%{state: :loading}), do: "Loading the current-run summary."
  def announcement(%{state: :empty}), do: "No active Aiur run."

  def announcement(%{state: :unavailable} = view) do
    "Current-run summary unavailable. " <> reasons_sentence(view)
  end

  def announcement(%{state: state} = view) when state in [:ready, :stale] do
    [
      run_sentence(state, view),
      counts_sentence(view.counts),
      progress_sentence(view.progress),
      eta_sentence(view.eta),
      "Health #{view.health.label}, freshness #{view.freshness.label}."
    ]
    |> Enum.join(" ")
  end

  def announcement(_view), do: "Current-run summary unavailable."

  @doc "Render reason atoms as a human-readable comma-separated clause."
  @spec reasons_text([atom()]) :: String.t()
  def reasons_text(reasons) when is_list(reasons) do
    Enum.map_join(reasons, ", ", &reason_phrase/1)
  end

  def reasons_text(_reasons), do: "unspecified"

  defp reasons_sentence(view) do
    case Map.get(view, :health, %{})[:reasons] do
      [_ | _] = reasons -> "Reasons: #{reasons_text(reasons)}."
      _ -> ""
    end
  end

  defp run_sentence(_state, _view), do: "Current run."

  defp counts_sentence(counts) do
    "#{counts.live} live, #{counts.remaining} remaining, #{counts.successful_terminal} succeeded of #{counts.total}."
  end

  defp progress_sentence(%{kind: :exact, percent: percent}), do: "Progress #{percent} percent exact."

  defp progress_sentence(%{kind: :partial, percent: percent} = progress) do
    qualifier = if progress.partial_lower_bound?, do: "at least ", else: ""

    "Progress #{qualifier}#{percent} percent from #{progress.current_member_count} of " <>
      "#{progress.total_member_count} members with current inputs, #{fact_status_text(progress.fact_status)}."
  end

  defp progress_sentence(%{kind: :pending} = progress) do
    "#{progress.progress_status_label}, #{progress.current_member_count} of " <>
      "#{progress.total_member_count} members with current inputs, #{fact_status_text(progress.fact_status)}."
  end

  defp progress_sentence(%{kind: :lower_bound, lower_bound_percent: nil}), do: "Progress coverage unknown."

  defp progress_sentence(%{kind: :lower_bound, lower_bound_percent: percent, coverage_percent: coverage}) do
    "Progress at least #{percent} percent, #{coverage_text(coverage)} of weight measured."
  end

  defp progress_sentence(_progress), do: "No weighted progress, zero eligible weight."

  defp coverage_text(nil), do: "an unknown share"
  defp coverage_text(coverage), do: "#{coverage} percent"

  defp eta_sentence(%{status: :available, label: label}), do: "ETA #{label}."
  defp eta_sentence(%{label: label}), do: "ETA #{label}."

  defp reason_phrase(:unhealthy_weight_facts), do: "progress inputs incomplete"

  defp reason_phrase(reason) when is_atom(reason) do
    reason |> Atom.to_string() |> String.replace("_", " ")
  end

  defp reason_phrase(reason), do: to_string(reason)

  # --- state ---------------------------------------------------------------

  defp state(_source, true), do: :stale

  defp state(source, false) do
    health = Map.get(source, :health, %{})
    counts = Map.get(source, :counts, %{})

    cond do
      Map.get(health, :status) == :unavailable and no_run?(source, counts) -> :empty
      Map.get(health, :status) == :unavailable -> :unavailable
      Map.get(source, :freshness, %{})[:status] == :stale -> :stale
      true -> :ready
    end
  end

  defp no_run?(source, counts) do
    reasons = source |> Map.get(:health, %{}) |> Map.get(:reasons, [])
    Map.get(counts, :total, 0) == 0 and reasons == [:invalid_run_window]
  end

  # --- counts --------------------------------------------------------------

  defp present_counts(counts) do
    %{
      live: Map.get(counts, :live, 0),
      remaining: Map.get(counts, :remaining, 0),
      successful_terminal: Map.get(counts, :successful_terminal, 0),
      non_work_terminal: Map.get(counts, :non_work_terminal, 0),
      unknown_state: Map.get(counts, :unknown_state, 0),
      total: Map.get(counts, :total, 0)
    }
  end

  # --- progress ------------------------------------------------------------

  defp present_progress(progress, weights) do
    exact = Map.get(progress, :exact)
    lower = Map.get(progress, :lower_bound)
    coverage = Map.get(progress, :coverage)
    current_facts = Map.get(progress, :current_facts, %{})
    eligible = Map.get(weights, :eligible, Map.get(progress, :denominator_weight, 0))
    kind = progress_kind(exact, current_facts, eligible)

    %{
      kind: kind,
      percent: progress_percent(kind, exact, current_facts),
      lower_bound_percent: percent(lower),
      coverage_percent: percent(coverage),
      partial_lower_bound?: Map.get(current_facts, :lower_bound?, false),
      fact_status: Map.get(current_facts, :status, :complete),
      current_member_count: Map.get(current_facts, :current_member_count, 0),
      total_member_count: Map.get(current_facts, :total_member_count, 0),
      missing_member_count: Map.get(current_facts, :missing_member_count, 0),
      denominator_weight: Map.get(progress, :denominator_weight, eligible),
      known_weight: Map.get(progress, :known_weight, 0),
      unknown_weight: Map.get(progress, :unknown_weight, 0),
      excluded_weight: Map.get(weights, :excluded, 0),
      excluded_count: Map.get(weights, :excluded_count, 0),
      defaulted_weight: Map.get(weights, :defaulted, 0),
      defaulted_count: Map.get(weights, :defaulted_count, 0)
    }
    |> present_progress_labels()
  end

  defp progress_kind(_exact, _current_facts, eligible) when eligible <= 0, do: :none
  defp progress_kind(exact, _current_facts, _eligible) when is_map(exact), do: :exact

  defp progress_kind(_exact, %{status: status, value: nil}, _eligible)
       when status in [:settling, :degraded],
       do: :pending

  defp progress_kind(_exact, %{status: status, value: value}, _eligible)
       when status in [:settling, :degraded] and is_map(value),
       do: :partial

  defp progress_kind(_exact, _current_facts, _eligible), do: :lower_bound

  defp progress_percent(:exact, exact, _current_facts), do: percent(exact)
  defp progress_percent(:partial, _exact, current_facts), do: percent(Map.get(current_facts, :value))
  defp progress_percent(_kind, _exact, _current_facts), do: nil

  defp present_progress_labels(%{kind: :partial} = progress) do
    prefix = if progress.partial_lower_bound?, do: "At least ", else: ""

    Map.merge(progress, %{
      display_percent_label: "#{prefix}#{progress.percent}%",
      current_members_label: "#{progress.current_member_count} of #{progress.total_member_count} members current",
      fact_status_label: fact_status_label(progress.fact_status),
      fact_status_detail: fact_status_detail(progress.fact_status)
    })
  end

  defp present_progress_labels(%{kind: :pending} = progress) do
    Map.merge(progress, %{
      progress_status_label: pending_progress_label(progress.fact_status),
      current_members_label: "#{progress.current_member_count} of #{progress.total_member_count} members current",
      fact_status_label: fact_status_label(progress.fact_status),
      fact_status_detail: fact_status_detail(progress.fact_status)
    })
  end

  defp present_progress_labels(progress), do: progress

  # --- elapsed -------------------------------------------------------------

  defp present_elapsed(run) do
    seconds = Map.get(run, :elapsed_wall_seconds)
    %{seconds: seconds, label: format_duration(seconds)}
  end

  # --- eta -----------------------------------------------------------------

  defp present_eta(eta, progress) do
    status = Map.get(eta, :status, :unavailable)

    %{
      status: status,
      duration_seconds: duration_seconds(Map.get(eta, :duration_seconds)),
      label: eta_label(status, eta, progress),
      formula_version: Map.get(eta, :formula_version),
      confidence: Map.get(eta, :confidence, :unavailable),
      sample_count: Map.get(eta, :sample_count, 0),
      reason: Map.get(eta, :reason)
    }
  end

  defp eta_label(:available, eta, _progress) do
    case duration_seconds(Map.get(eta, :duration_seconds)) do
      nil -> "Estimating"
      seconds -> "About #{format_duration(seconds)} remaining"
    end
  end

  defp eta_label(_status, %{reason: :unhealthy_weight_facts}, progress) do
    case Map.get(progress, :fact_status) do
      :settling -> "ETA pending — progress inputs are still settling"
      :degraded -> "ETA unavailable — progress is not updating"
      _status -> "ETA unavailable — progress inputs incomplete"
    end
  end

  defp eta_label(_status, eta, _progress), do: eta_reason_label(Map.get(eta, :reason))

  defp eta_reason_label(:invalid_run_window), do: "Unavailable — no valid run window"
  defp eta_reason_label(:unhealthy_membership), do: "Unavailable — the unit list could not be read"
  defp eta_reason_label(:membership_not_fresh), do: "Unavailable — the unit list is out of date"
  defp eta_reason_label(:truncated_membership), do: "Unavailable — not all units are counted"
  defp eta_reason_label(:zero_eligible_weight), do: "Unavailable — no eligible weight"
  defp eta_reason_label(:insufficient_successful_completions), do: "Unavailable — fewer than two completions"
  defp eta_reason_label(:insufficient_elapsed_time), do: "Unavailable — under ten minutes elapsed"
  defp eta_reason_label(:zero_completed_weight), do: "Unavailable — no completed weight yet"
  defp eta_reason_label(_reason), do: "Unavailable"

  # --- health / freshness --------------------------------------------------

  defp present_health(health) do
    status = Map.get(health, :status, :unavailable)
    %{status: status, reasons: Map.get(health, :reasons, []), label: health_label(status)}
  end

  defp health_label(:healthy), do: "Healthy"
  defp health_label(:partial), do: "Partial"
  defp health_label(:unavailable), do: "Unavailable"
  defp health_label(_status), do: "Unknown"

  defp present_freshness(freshness) do
    status = Map.get(freshness, :status, :unknown)
    %{status: status, label: freshness_label(status)}
  end

  defp freshness_label(:fresh), do: "Fresh"
  defp freshness_label(:partial), do: "Partial"
  defp freshness_label(:stale), do: "Healthy"
  defp freshness_label(:unavailable), do: "Unavailable"
  defp freshness_label(_status), do: "Unknown"

  defp fact_status_text(status), do: status |> fact_status_label() |> String.downcase()
  defp fact_status_label(:settling), do: "Still settling"
  defp fact_status_label(:degraded), do: "Not updating"
  defp fact_status_label(_status), do: "Current"
  defp fact_status_detail(:settling), do: "progress inputs are still settling"
  defp fact_status_detail(:degraded), do: "progress is not updating"
  defp fact_status_detail(_status), do: "progress inputs are current"
  defp pending_progress_label(:settling), do: "Progress not computed yet"
  defp pending_progress_label(:degraded), do: "Progress unavailable"

  # --- shared helpers ------------------------------------------------------

  defp available?(snapshot) do
    run_valid? = snapshot |> Map.get(:run, %{}) |> Map.get(:valid?, false)
    status = snapshot |> Map.get(:health, %{}) |> Map.get(:status)
    run_valid? and status in [:healthy, :partial]
  end

  defp same_run?(current, incoming) do
    current_id = current |> Map.get(:run, %{}) |> Map.get(:id)
    incoming_id = incoming |> Map.get(:run, %{}) |> Map.get(:id)
    is_binary(current_id) and current_id == incoming_id
  end

  # Round a reduced `%{numerator, denominator}` fraction to an integer percent.
  defp percent(%{numerator: numerator, denominator: denominator}) when is_integer(denominator) and denominator > 0 do
    round(numerator * 100 / denominator)
  end

  defp percent(_fraction), do: nil

  defp duration_seconds(%{numerator: numerator, denominator: denominator}) when is_integer(denominator) and denominator > 0 do
    round(numerator / denominator)
  end

  defp duration_seconds(seconds) when is_integer(seconds) and seconds >= 0, do: seconds
  defp duration_seconds(_value), do: nil

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 0 do
    hours = div(seconds, 3_600)
    minutes = seconds |> rem(3_600) |> div(60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m"
      true -> "under 1m"
    end
  end

  defp format_duration(_seconds), do: "—"
end
