defmodule AiurWeb.OperatorControlCenter.UnitsPresenter.Catalog do
  @moduledoc false

  alias Aiur.Projections.UnitsRow.Sources
  alias AiurWeb.OperatorControlCenter.UnitsPresentation

  @spec catalog_status(map()) :: :ready | :empty | :stale | :unavailable
  def catalog_status(%{health: %{membership: :unavailable}, rows: []}), do: :unavailable
  def catalog_status(%{health: %{membership: :unavailable}}), do: :stale
  def catalog_status(%{health: %{membership: :degraded}}), do: :stale

  def catalog_status(%{health: %{membership: status}, rows: []})
      when status not in [:healthy, :available],
      do: :unavailable

  def catalog_status(%{health: %{membership: status}})
      when status not in [:healthy, :available],
      do: :stale

  def catalog_status(%{freshness: %{membership: %{status: status}}}) when status in [:stale, :unknown, :unavailable],
    do: :stale

  # A degraded fleet source must be visible on the catalog itself: a stale
  # `Active 0` and a current `Active 0` mean different things, so the catalog
  # is never presented as ready while the fleet view behind it is last-known-good.
  def catalog_status(%{rows: []} = snapshot), do: if(fleet_view_degraded?(snapshot), do: :stale, else: :empty)
  def catalog_status(snapshot), do: if(fleet_view_degraded?(snapshot), do: :stale, else: :ready)

  defp fleet_view_degraded?(snapshot) do
    fleet_health(snapshot) not in [:healthy, :available] or
      fleet_freshness_degraded?(snapshot)
  end

  # A fleet view only counts as "stale" once it is genuinely old; a snapshot
  # marked stale a few seconds after its last publish is still effectively
  # current and must not demote the catalog to last-known-good. The row
  # projection admits rows on the same window, so the catalog's status and its
  # contents can never disagree about which fleet views still count.
  #
  # `Sources.fleet_stale_after_seconds/0` is read at call time rather than
  # captured into a module attribute: the window derives from the effective poll
  # cadence, which changes at runtime with idle backoff, and a compile-time
  # capture would freeze it at whatever the cadence was when this module built.
  #
  # A `:stale` freshness is only a degradation once the view is actually old;
  # `:unknown`/`:unavailable` have no age to compare and stay degraded. A stale
  # view with no age at all cannot be judged against the window, and the row
  # projection drops it for exactly that reason — so the catalog must not then
  # call itself ready over the rows that disappeared.
  defp fleet_freshness_degraded?(snapshot) do
    case {fleet_freshness_status(snapshot), fleet_age_seconds(snapshot)} do
      {:stale, age_seconds} when is_integer(age_seconds) -> age_seconds >= Sources.fleet_stale_after_seconds()
      {:stale, _no_age} -> true
      {status, _age_seconds} when status in [:unknown, :unavailable] -> true
      _freshness -> false
    end
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

  @spec catalog_message(atom(), map(), map()) :: String.t() | nil
  def catalog_message(:ready, _membership, _snapshot), do: nil
  def catalog_message(:empty, _membership, _snapshot), do: "No units in this run yet."

  # Never quote a healthy membership as the reason for a stale catalog: the
  # cause is whichever source is actually degraded.
  def catalog_message(:stale, membership, snapshot),
    do: membership_fault(membership) || stale_source_message(snapshot)

  def catalog_message(:unavailable, membership, _snapshot),
    do: membership_fault(membership) || "Fleet data is unavailable."

  defp membership_fault(membership) do
    case Map.get(membership, :health) do
      health when health in [:healthy, :available] -> nil
      _degraded_or_unknown -> Map.get(membership, :health_message)
    end
  end

  defp stale_source_message(snapshot) do
    cond do
      fleet_health(snapshot) not in [:healthy, :available] ->
        "#{stale_lead(snapshot)} Fleet data is unavailable."

      fleet_freshness_degraded?(snapshot) ->
        "Fleet updates are pending." <> fleet_age_phrase(snapshot)

      true ->
        stale_lead(snapshot)
    end
  end

  # The stale lead is intentionally plain: the dashboard no longer tells the
  # operator that a view is out of date, so the message names the current state
  # without "last saw" vocabulary.
  defp stale_lead(%{rows: []}), do: "No live units."
  defp stale_lead(_snapshot), do: "The fleet is still counting units."

  defp fleet_age_phrase(snapshot) do
    case fleet_age_seconds(snapshot) do
      nil -> ""
      age_seconds -> " Last updated #{UnitsPresentation.age_label(age_seconds)} ago."
    end
  end
end
