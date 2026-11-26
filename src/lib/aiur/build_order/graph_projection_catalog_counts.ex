defmodule Aiur.BuildOrder.GraphProjection.CatalogCounts do
  @moduledoc false

  # Catalog epic/wave count carry-forward and the labelled-read cadence, record and failure class.
  # Runs inside the projection process: every `self()` here is the GenServer.

  alias Aiur.BuildOrder.{Catalog, ProviderResult}
  alias Aiur.BuildOrder.GraphProjection.Schedule

  # How many labelled-read intervals a carried epic/wave count may survive
  # before the columns fall back to "Unresolved". Two gives one missed labelled
  # read of slack without letting a broken labelled cadence publish a number of
  # unbounded age.
  @carry_grace_intervals 2

  # An unlabelled catalog poll cannot resolve epic/wave counts, so it inherits
  # the previous generation's — but only for roots `Catalog.carry_forward_counts/2`
  # can match, and only while the labelled cadence is actually keeping up.
  #
  # A *labelled* read is authoritative: if it read the member labels and still
  # could not resolve a count, the honest answer is "Unresolved", not the number
  # from before. Inheriting there would let one stale count survive every
  # expensive refresh that was supposed to correct it.
  @spec carry_catalog_counts(map(), term(), map(), :catalog | {:selected, Aiur.TrackerIdentity.t()}, map()) :: term()
  def carry_catalog_counts(state, %Catalog{} = candidate, %{data: %Catalog{} = previous}, :catalog, inflight) do
    if labelled_read?(inflight) or carry_expired?(state) do
      candidate
    else
      Catalog.carry_forward_counts(candidate, previous)
    end
  end

  def carry_catalog_counts(_state, candidate, _entry, _scope, _inflight), do: candidate

  # A labelled read that *succeeded* and still published no count for a
  # populated root did not observe a tracker error — no error occurred at all.
  # The gap is our own: the members ran past the planning page bound. Reporting
  # that as `:upstream` blamed GitHub for an Aiur query limit (#2250).
  @spec put_catalog_count_resolution(map(), term(), :catalog | {:selected, Aiur.TrackerIdentity.t()}, map()) :: {map(), term()}
  def put_catalog_count_resolution(state, %Catalog{} = catalog, :catalog, inflight) do
    if labelled_read?(inflight) do
      failure = if unresolved_populated_counts?(catalog), do: :incomplete, else: nil
      state = %{state | catalog_labels_failure: failure, catalog_labels_failure_reset_at: nil}
      {state, Catalog.put_count_resolution_failure(catalog, failure)}
    else
      catalog =
        Catalog.put_count_resolution_failure(catalog, state.catalog_labels_failure, reset_at: state.catalog_labels_failure_reset_at)

      {state, catalog}
    end
  end

  def put_catalog_count_resolution(state, candidate, _scope, _inflight), do: {state, candidate}

  defp unresolved_populated_counts?(%Catalog{entries: entries}) do
    Enum.any?(entries, fn
      %{member_count: count, epic_count: epics, phase_count: phases} when is_integer(count) and count > 0 ->
        is_nil(epics) or is_nil(phases)

      _entry ->
        false
    end)
  end

  defp labelled_read?(%{member_labels?: true}), do: true
  defp labelled_read?(_inflight), do: false

  # Carrying is a bridge between labelled reads, not a substitute for them. If
  # the labelled read has been failing for longer than the grace window, the
  # counts are no longer a number we can stand behind, so the columns fall back
  # to "Unresolved" rather than asserting an unbounded-age figure.
  defp carry_expired?(%{catalog_labels_ok_ms: nil}), do: false

  defp carry_expired?(%{catalog_labels_ok_ms: ok_ms} = state),
    do: Schedule.now_ms(state) - ok_ms > state.policy.catalog_labels_refresh_ms * @carry_grace_intervals

  # The cadence is stamped on success, not on dispatch: a labelled read that
  # failed bought nothing, so it must not push the next one out by a full
  # interval. It must not retry immediately either — a labelled read that fails
  # deterministically (a timeout on the much larger response, a node-limit
  # rejection, point exhaustion) would otherwise make *every* catalog poll buy
  # the expensive query, which is exactly the budget burn #1766 is about. So a
  # failed labelled read backs off geometrically, and the cheap reads in between
  # keep the catalog publishing.
  @spec record_catalog_labels_read(map(), :catalog | {:selected, Aiur.TrackerIdentity.t()}, map()) :: map()
  def record_catalog_labels_read(state, :catalog, %{member_labels?: true}) do
    now_ms = Schedule.now_ms(state)

    %{
      state
      | catalog_labels_read_ms: now_ms,
        catalog_labels_ok_ms: now_ms,
        catalog_labels_penalty_ms: 0,
        catalog_labels_failures: 0
    }
  end

  def record_catalog_labels_read(state, _scope, _inflight), do: state

  @spec record_catalog_labels_failure(map(), :catalog | {:selected, Aiur.TrackerIdentity.t()}, map(), term(), term()) :: map()
  def record_catalog_labels_failure(state, :catalog, %{member_labels?: true}, failure, provider_result) do
    failures = state.catalog_labels_failures + 1
    class = count_resolution_failure(failure)

    %{
      state
      | catalog_labels_read_ms: Schedule.now_ms(state),
        catalog_labels_failure: class,
        catalog_labels_failure_reset_at: failure_reset_at(class, provider_result),
        catalog_labels_failures: failures,
        catalog_labels_penalty_ms: labels_penalty_ms(state, failures)
    }
  end

  def record_catalog_labels_failure(state, _scope, _inflight, _failure, _provider_result), do: state

  # "Budget exhausted" with no horizon is only half an answer: the operator
  # still cannot tell whether to wait a minute or an hour. Both hold shapes and
  # the GitHub rate-limit response already carry the reset, so surface it.
  defp failure_reset_at(class, %ProviderResult{error: error}) when class in [:budget, :rate_limited] do
    case error do
      {:aiur, :locally_held, %{reset_at: %DateTime{} = reset_at}} -> reset_at
      {:github, _classification, %{reset_at: %DateTime{} = reset_at}} -> reset_at
      _error -> nil
    end
  end

  defp failure_reset_at(_class, _provider_result), do: nil

  # Enumerated, never defaulted. A stated cause is acted on: an operator told
  # "the tracker returned an upstream error" checks GitHub's status page, sees
  # green, and files a ticket against Aiur — when the real fault was their own
  # expired token. A wrong reason is worse than the bare "Unresolved" it
  # replaced, so a class this function does not recognise stays `nil` and the
  # cell keeps admitting ignorance (#2250).
  defp count_resolution_failure(failure) when failure in [:call_budget, :page_budget, :budget], do: :budget
  defp count_resolution_failure(:rate_limited), do: :rate_limited
  defp count_resolution_failure(:timeout), do: :timeout
  defp count_resolution_failure(failure) when failure in [:unreachable, :dns, :tls, :transport], do: :unreachable
  defp count_resolution_failure(:permission), do: :permission
  defp count_resolution_failure(failure) when failure in [:schema, :structurally_invalid], do: :schema

  # Aiur's own bounds and consistency checks. The read reached GitHub and got an
  # answer; we could not turn all of it into counts. Blaming the tracker for
  # these was the third defect: our page bound is not their outage.
  defp count_resolution_failure(failure)
       when failure in [
              :incomplete,
              :graphql_partial,
              :pagination_mismatch,
              :catalog_overflow,
              :member_overflow,
              :connection_overflow,
              :duplicate_identity,
              :provider_identity_mismatch
            ],
       do: :incomplete

  defp count_resolution_failure(_failure), do: nil

  defp labels_penalty_ms(state, failures) do
    backoff = Schedule.catalog_bound_ms(state) * Integer.pow(2, min(failures - 1, 16))
    min(backoff, state.policy.catalog_labels_refresh_ms)
  end

  # Only the catalog has a labelled variant, and it is bought on its own slow
  # cadence because the per-member `labels` connection costs ~26 GraphQL points
  # against a 5,000-points/hour budget versus ~1 without it (#1766). The first
  # read under an authority is always labelled so the page resolves promptly;
  # after that the cheap reads carry the resolved counts forward.
  @spec catalog_labels_due?(map(), :catalog | {:selected, Aiur.TrackerIdentity.t()}) :: boolean()
  def catalog_labels_due?(_state, {:selected, _identity}), do: false
  def catalog_labels_due?(%{catalog_labels_read_ms: nil}, :catalog), do: true

  def catalog_labels_due?(%{catalog_labels_read_ms: last_ms} = state, :catalog),
    do: Schedule.now_ms(state) - last_ms >= labels_interval_ms(state)

  # After a failed labelled read the gate is the backoff penalty, not the full
  # cadence, so a transient failure costs one poll rather than ten minutes of
  # unresolved counts — while a persistent one still backs off to the cadence.
  defp labels_interval_ms(%{catalog_labels_penalty_ms: penalty}) when is_integer(penalty) and penalty > 0, do: penalty
  defp labels_interval_ms(state), do: state.policy.catalog_labels_refresh_ms
end
