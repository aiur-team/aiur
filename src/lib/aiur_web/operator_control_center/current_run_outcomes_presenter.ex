defmodule AiurWeb.OperatorControlCenter.CurrentRunOutcomesPresenter do
  @moduledoc """
  Formats the DASH-032 `Aiur.CurrentRunOutcomeSnapshot` snapshot into a named,
  screen-reader-friendly view for the Units page `Finished this run` region.

  This presenter performs no qualification: membership, run-window, branch
  linkage, and ordering all come straight from the daemon-owned snapshot. Every
  card is a member of `snapshot.outcomes` in snapshot order; the presenter never
  selects, sorts, labels, or promotes an outcome from `observed_run_id`, visible
  rows, or event time. It only formats those facts and keeps the distinct states
  (loading, healthy, healthy-empty, partial, stale, unavailable, new-run,
  truncated) visibly separate.

  ## Truthful `Finished this run` claim

  The region is labelled `Finished this run` only when the entire snapshot is a
  complete, non-retained result pinned to a canonical current-run membership
  generation. A partial, stale, unavailable, retained, or run-transition
  snapshot uses a neutral heading and never renders a confident no-outcomes
  claim.

  ## Last-known-good retention

  `reconcile/2` decides which snapshot to display. A newly-received unavailable
  snapshot never replaces a healthy same-run region with an empty one: it
  retains the prior same-run snapshot labelled stale. A new run generation or an
  unconfirmable run shows the unavailable snapshot rather than presenting the
  prior run's outcomes as current.
  """

  alias Aiur.TrackerIdentity

  @type snapshot :: map()
  @type view :: map()

  @title_limit 200
  @summary_limit 280
  @identifier_limit 120
  @run_id_display 12

  @doc """
  Given the snapshot currently displayed (`current`, may be `nil`) and an
  `incoming` snapshot, return `{source, retained?}` where `source` is the
  snapshot to present and `retained?` is true when `source` is a stale
  last-known-good retained across an unavailable update.

  An available incoming snapshot is always adopted. An unavailable incoming
  snapshot retains `current` only when `current` is a healthy same-run snapshot;
  otherwise the unavailable snapshot is shown so a new run or an unconfirmable
  run never presents the prior run's outcomes as current.
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
  last-known-good. When a snapshot is retained across a failed refresh the cards
  come from `source` but health/freshness come from `status_source` (the
  incoming unavailable snapshot) so the labels report the failed refresh.
  """
  @spec present(snapshot() | nil, boolean(), snapshot() | nil) :: view()
  def present(source, retained? \\ false, status_source \\ nil)

  def present(source, retained?, status_source) when is_map(source) do
    status = status_source || source
    state = state(source, retained?)

    %{
      state: state,
      retained?: retained?,
      finished_this_run?: finished_this_run?(source, state, retained?),
      heading: heading(source, state, retained?),
      generation: Map.get(source, :generation, 0),
      run_id: run_id(source),
      membership_generation: membership_generation(source),
      counts: present_counts(Map.get(source, :counts, %{})),
      truncated?: Map.get(source, :truncated?, false) == true,
      limit: Map.get(source, :limit),
      outcomes: present_outcomes(source, state),
      health: present_health(Map.get(status, :health, %{})),
      freshness: present_freshness(Map.get(status, :freshness, %{}))
    }
  end

  def present(_source, _retained?, _status_source) do
    %{
      state: :loading,
      retained?: false,
      finished_this_run?: false,
      heading: neutral_heading(),
      generation: 0,
      run_id: nil,
      membership_generation: nil,
      counts: present_counts(%{}),
      truncated?: false,
      limit: nil,
      outcomes: [],
      health: present_health(%{}),
      freshness: present_freshness(%{})
    }
  end

  @doc "A single bounded screen-reader announcement summarising the presented `view`."
  @spec announcement(view()) :: String.t()
  def announcement(%{state: :loading}), do: "Loading current-run outcomes."

  def announcement(%{state: :new_run}),
    do: "A new run is starting. Previous-run outcomes are cleared and none have qualified yet."

  def announcement(%{state: :unavailable} = view) do
    "Current-run outcomes unavailable. " <> reasons_sentence(view)
  end

  def announcement(%{state: :healthy_empty} = view) do
    "#{heading_sentence(view)} No repository merges have finished this run yet."
  end

  def announcement(%{state: state} = view) when state in [:healthy, :partial, :stale] do
    [
      heading_sentence(view),
      count_sentence(view),
      caveat_sentence(state),
      "Health #{view.health.label}, freshness #{view.freshness.label}."
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  def announcement(_view), do: "Current-run outcomes unavailable."

  @doc "Render reason atoms as a human-readable comma-separated clause."
  @spec reasons_text([atom()]) :: String.t()
  def reasons_text(reasons) when is_list(reasons) do
    Enum.map_join(reasons, ", ", &reason_phrase/1)
  end

  def reasons_text(_reasons), do: "unspecified"

  # --- state ---------------------------------------------------------------

  defp state(_source, true), do: :stale

  defp state(source, false) do
    case Map.get(source, :state) do
      :unavailable -> if run_transition?(source), do: :new_run, else: :unavailable
      state when state in [:healthy, :healthy_empty, :partial, :stale] -> state
      _other -> :unavailable
    end
  end

  # A run-identity transition (restart / new run before qualification) is
  # distinct from a merge/membership provider outage. Both surface as an
  # unavailable snapshot, so split on the run-window/membership-mismatch reasons.
  defp run_transition?(source) do
    reasons = source |> Map.get(:health, %{}) |> Map.get(:reasons, [])
    Enum.any?(reasons, &(&1 in [:invalid_run_window, :run_membership_mismatch]))
  end

  # --- heading / label gate ------------------------------------------------

  defp finished_this_run?(source, state, retained?) do
    state in [:healthy, :healthy_empty] and not retained? and
      is_binary(run_id(source)) and is_integer(membership_generation(source))
  end

  defp heading(_source, _state, _retained?), do: neutral_heading()

  defp neutral_heading, do: "Current-run outcomes"

  # --- counts --------------------------------------------------------------

  defp present_counts(counts) do
    %{
      input: Map.get(counts, :input, 0),
      invalid: Map.get(counts, :invalid, 0),
      deduplicated: Map.get(counts, :deduplicated, 0),
      qualified: Map.get(counts, :qualified, 0),
      returned: Map.get(counts, :returned, 0)
    }
  end

  # --- outcomes ------------------------------------------------------------

  # A degraded run-identity/provider state never surfaces cards, even if a
  # malformed snapshot carried a non-empty list. Retained (:stale) and :partial
  # results still show their outcomes, with a caveat.
  defp present_outcomes(_source, state) when state in [:unavailable, :new_run], do: []

  defp present_outcomes(source, _state) do
    source
    |> Map.get(:outcomes, [])
    |> List.wrap()
    |> Enum.map(&outcome_row/1)
  end

  defp outcome_row(outcome) do
    observation = Map.get(outcome, :observation, %{})
    member = Map.get(outcome, :member, %{})

    %{
      id: dom_id(outcome),
      number: Map.get(outcome, :number),
      title: bounded(Map.get(outcome, :title), @title_limit),
      summary: bounded(Map.get(outcome, :summary), @summary_limit),
      url: trusted_url(Map.get(outcome, :url)),
      ticket_identity: identity_label(Map.get(member, :identity)),
      merged_at: Map.get(outcome, :merged_at),
      backfilled?: Map.get(observation, :backfilled?, false) == true,
      live_observed?: Map.get(observation, :live_observed?, false) == true,
      observed_run_id: observed_run_display(observation)
    }
  end

  defp dom_id(outcome) do
    key = Map.get(outcome, :id) || Map.get(outcome, :number) || Map.get(outcome, :merge_commit_sha)
    "current-run-outcome-#{safe_token(key)}"
  end

  defp safe_token(value) when is_binary(value), do: value |> String.replace(~r/[^\w-]/, "-") |> String.slice(0, 64)
  defp safe_token(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_token(_value), do: "unknown"

  # Observation provenance is shown for auditability only; it never selects,
  # labels, sorts, or promotes an outcome.
  defp observed_run_display(%{live_observed?: true, observed_run_id: run_id}) when is_binary(run_id),
    do: String.slice(run_id, 0, @run_id_display)

  defp observed_run_display(_observation), do: nil

  # Canonical ticket display identity, matching the Units table convention.
  defp identity_label(%TrackerIdentity{owner: owner, repository: repository, identifier: identifier})
       when is_binary(owner) and is_binary(repository) and is_binary(identifier) do
    bounded("#{owner}/#{repository} ##{identifier}", @identifier_limit)
  end

  defp identity_label(_identity), do: nil

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
  defp freshness_label(:stale), do: "Stale"
  defp freshness_label(:unavailable), do: "Unavailable"
  defp freshness_label(_status), do: "Unknown"

  # --- announcement helpers ------------------------------------------------

  defp heading_sentence(%{heading: heading}), do: "#{heading}."

  defp count_sentence(%{counts: %{returned: returned, qualified: qualified}}) when qualified > returned,
    do: "Showing #{returned} of #{qualified} qualified outcomes."

  defp count_sentence(%{counts: %{returned: returned}}) do
    "#{returned} #{pluralize(returned, "outcome", "outcomes")}."
  end

  defp caveat_sentence(:partial), do: "Results may be incomplete."
  defp caveat_sentence(:stale), do: "Showing the outcomes we last read; the refresh did not confirm."
  defp caveat_sentence(_state), do: ""

  defp reasons_sentence(view) do
    case Map.get(view, :health, %{})[:reasons] do
      [_ | _] = reasons -> "Reasons: #{reasons_text(reasons)}."
      _ -> ""
    end
  end

  defp reason_phrase(reason) when is_atom(reason) do
    reason |> Atom.to_string() |> String.replace("_", " ")
  end

  defp reason_phrase(reason), do: to_string(reason)

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural

  # --- shared helpers ------------------------------------------------------

  defp available?(snapshot) do
    status = snapshot |> Map.get(:health, %{}) |> Map.get(:status)
    status in [:healthy, :partial]
  end

  defp same_run?(current, incoming) do
    current_id = run_id(current)
    incoming_id = run_id(incoming)
    is_binary(current_id) and current_id == incoming_id
  end

  defp run_id(snapshot), do: snapshot |> Map.get(:run, %{}) |> Map.get(:id)
  defp membership_generation(snapshot), do: snapshot |> Map.get(:membership, %{}) |> Map.get(:generation)

  defp trusted_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> value
      _uri -> nil
    end
  end

  defp trusted_url(_value), do: nil

  defp bounded(value, limit) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: String.slice(trimmed, 0, limit)
  end

  defp bounded(_value, _limit), do: nil
end
