defmodule Aiur.BuildOrder.GraphProjection.Policy do
  @moduledoc false

  alias Aiur.BuildOrder.{Catalog, Diagnostic, ProviderHealth, ProviderResult, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity

  @minimum_retry_ms 1_000
  @maximum_provider_retry_ms 300_000

  @spec root_key(TrackerIdentity.t()) :: tuple() | nil
  def root_key(%TrackerIdentity{} = identity), do: TrackerIdentity.github_key(identity)
  def root_key(_identity), do: nil

  @spec catalog_topic(TrackerIdentity.repository()) :: String.t()
  def catalog_topic(repository), do: topic("catalog", repository)

  @spec selected_topic(TrackerIdentity.t()) :: String.t()
  def selected_topic(identity), do: topic("selected", root_key(identity))

  @spec unavailable_entry(:catalog | {:selected, TrackerIdentity.t()}, integer()) :: map()
  def unavailable_entry(scope, now_ms) do
    %{
      scope: scope,
      data: nil,
      generation: :unknown,
      last_success_ms: nil,
      last_access_ms: now_ms,
      health: ProviderHealth.new(:unknown, :unavailable, false),
      inflight: nil,
      timer: nil,
      timer_token: 0,
      demanders: MapSet.new()
    }
  end

  @spec snapshot(map(), TrackerIdentity.repository() | :unknown, Snapshot.authority_epoch(), integer(), pos_integer()) ::
          Snapshot.t()
  def snapshot(entry, repository, authority_epoch, now_ms, interval_ms) do
    health = aged_health(entry, now_ms, interval_ms)

    %Snapshot{
      scope: entry.scope,
      repository: repository,
      authority_epoch: authority_epoch,
      generation: entry.generation,
      data: entry.data,
      health: health
    }
  end

  @spec due?(map(), integer(), pos_integer()) :: boolean()
  def due?(%{last_success_ms: nil}, _now_ms, _interval_ms), do: true

  def due?(%{last_success_ms: last_success_ms}, now_ms, interval_ms),
    do: now_ms - last_success_ms >= interval_ms

  @spec apply_success(map(), term(), pos_integer(), DateTime.t(), integer()) :: map()
  def apply_success(entry, candidate, generation, now, now_ms) do
    health =
      ProviderHealth.new(generation, :healthy, true,
        observed_at: now,
        last_success_at: now,
        last_attempt_at: entry.health.last_attempt_at,
        retry_count: 0
      )

    %{
      entry
      | data: candidate,
        generation: generation,
        last_success_ms: now_ms,
        health: health,
        inflight: nil
    }
  end

  @spec apply_failure(map(), atom(), DateTime.t(), DateTime.t() | nil, boolean()) :: map()
  def apply_failure(entry, failure, now, next_retry_at, scheduled?) do
    state = failure_state(entry.data, failure)

    health =
      ProviderHealth.new(entry.generation, state, false,
        observed_at: entry.health.observed_at,
        last_success_at: entry.health.last_success_at,
        last_attempt_at: now,
        failure: failure,
        retry_count: entry.health.retry_count + 1,
        next_retry_at: if(scheduled?, do: next_retry_at)
      )

    %{entry | health: health, inflight: nil}
  end

  @spec refreshing(map(), DateTime.t()) :: map()
  def refreshing(entry, now) do
    health =
      ProviderHealth.new(entry.generation, entry.health.state, not is_nil(entry.data),
        refreshing?: true,
        observed_at: entry.health.observed_at,
        last_success_at: entry.health.last_success_at,
        last_attempt_at: now,
        failure: entry.health.failure,
        retry_count: entry.health.retry_count,
        next_retry_at: entry.health.next_retry_at
      )

    %{entry | health: health}
  end

  @spec complete_candidate(term(), :catalog | {:selected, TrackerIdentity.t()}, TrackerIdentity.repository()) ::
          {:ok, Catalog.t() | SelectedRoot.t()} | {:error, atom(), ProviderResult.t() | nil}
  def complete_candidate({:ok, %ProviderResult{status: :complete, candidate: %Catalog{} = catalog}}, :catalog, repository) do
    if catalog_repository?(catalog, repository),
      do: {:ok, catalog},
      else: {:error, :provider_identity_mismatch, nil}
  end

  def complete_candidate(
        {:ok, %ProviderResult{status: :complete, candidate: %SelectedRoot{} = selected}},
        {:selected, expected},
        repository
      ) do
    cond do
      not selected_repository?(selected, expected, repository) ->
        {:error, :provider_identity_mismatch, nil}

      SelectedRoot.structurally_valid?(selected) ->
        {:ok, selected}

      # A structural verdict is a claim about the operator's Build Order, so it
      # may only be made from data we actually read. When every diagnostic on
      # the candidate is provider-sourced ("we could not fetch this"), the graph
      # is not malformed — the read is — and the specific read fault is reported
      # instead of a fabricated `:structurally_invalid` (#1777).
      structurally_defective?(selected) ->
        {:error, :structurally_invalid, nil}

      true ->
        {:error, provider_failure_class(selected), nil}
    end
  end

  def complete_candidate({:error, %ProviderResult{} = result}, _scope, _repository),
    do: {:error, failure_class(result.error), result}

  def complete_candidate({:error, reason}, _scope, _repository) when is_atom(reason),
    do: {:error, failure_class(reason), nil}

  def complete_candidate(%ProviderResult{} = result, scope, repository),
    do: complete_candidate(provider_result_tuple(result), scope, repository)

  def complete_candidate(_result, _scope, _repository), do: {:error, :provider_unavailable, nil}

  @spec retry_delay_ms(non_neg_integer(), pos_integer(), ProviderResult.t() | nil, DateTime.t()) :: pos_integer()
  def retry_delay_ms(retry_count, interval_ms, result, now) do
    case provider_retry_ms(result, now) do
      nil -> min(interval_ms, @minimum_retry_ms * Integer.pow(2, min(retry_count, 8)))
      delay -> delay
    end
  end

  @spec failure_class(term()) :: atom()
  def failure_class({:github, classification, _detail}) when classification in [:auth, :forbidden], do: :permission

  def failure_class({:github, classification, _detail}) when classification in [:rate_limited, :secondary_rate_limit],
    do: :rate_limited

  def failure_class(reason) when reason in [:catalog_overflow, :member_overflow], do: reason
  def failure_class(:page_budget_exhausted), do: :page_budget
  def failure_class(:call_budget_exhausted), do: :call_budget
  def failure_class(:structurally_invalid), do: :structurally_invalid

  # Faults the provider names precisely. Each already records a matching
  # `Diagnostic`, and folding them into `:provider_unavailable` threw that
  # evidence away: the operator was told GitHub was down when the real fault was
  # an inconsistent page, a repeated identity or a misconfigured authority
  # (#1777).
  def failure_class(reason)
      when reason in [
             :pagination_mismatch,
             :duplicate_identity,
             :provider_identity_mismatch,
             :invalid_planning_bounds,
             :invalid_planning_authority,
             :connection_overflow,
             :graphql_partial
           ],
      do: reason

  def failure_class(:missing_github_token), do: :permission
  def failure_class(:provider_schema), do: :schema

  def failure_class(reason)
      when reason in [:invalid_connection, :invalid_graphql_response, :invalid_root, :schema],
      do: :schema

  def failure_class(reason) when reason in [:timeout, :transport, :rate_limited, :permission], do: reason
  def failure_class(:invalid_requested_root), do: :invalid_root
  def failure_class(_reason), do: :provider_unavailable

  # A defect the read actually observed: a bad root summary, or any diagnostic
  # that is not provider-sourced (duplicate identity, malformed member, member
  # overflow). Those are real claims about the graph.
  defp structurally_defective?(%SelectedRoot{root: root, diagnostics: diagnostics}) do
    not RootSummary.valid?(root) or Enum.any?(diagnostics, &(not Diagnostic.provider_sourced?(&1)))
  end

  defp structurally_defective?(_selected), do: true

  defp provider_failure_class(%SelectedRoot{diagnostics: diagnostics}) do
    diagnostics
    |> Enum.find(&Diagnostic.provider_sourced?/1)
    |> case do
      %Diagnostic{code: code} -> failure_class(code)
      _ -> :provider_unavailable
    end
  end

  defp aged_health(%{data: nil, health: health}, _now_ms, _interval_ms), do: health

  defp aged_health(%{health: %ProviderHealth{refreshing?: true} = health}, _now_ms, _interval_ms),
    do: health

  defp aged_health(%{health: %ProviderHealth{failure: failure} = health}, _now_ms, _interval_ms)
       when not is_nil(failure),
       do: health

  defp aged_health(%{last_success_ms: last_success_ms, health: health}, now_ms, interval_ms) do
    if now_ms - last_success_ms >= interval_ms,
      do: %{health | state: :stale},
      else: health
  end

  defp failure_state(nil, :structurally_invalid), do: :structurally_invalid
  defp failure_state(nil, _failure), do: :unavailable
  defp failure_state(_data, _failure), do: :stale

  defp provider_result_tuple(%ProviderResult{status: :complete} = result), do: {:ok, result}
  defp provider_result_tuple(%ProviderResult{} = result), do: {:error, result}

  defp catalog_repository?(%Catalog{entries: entries}, repository) do
    Enum.all?(entries, fn
      %{identity: nil} -> true
      %{identity: identity} -> identity_in_repository?(identity, repository)
      _entry -> true
    end)
  end

  defp selected_repository?(%SelectedRoot{root: %{identity: identity}}, expected, repository) do
    identity_in_repository?(identity, repository) and root_key(identity) == root_key(expected)
  end

  defp selected_repository?(_selected, _expected, _repository), do: false

  defp identity_in_repository?(%TrackerIdentity{owner: owner, repository: name}, {expected_owner, expected_name}) do
    String.downcase(owner) == String.downcase(expected_owner) and
      String.downcase(name) == String.downcase(expected_name)
  end

  defp identity_in_repository?(_identity, _repository), do: false

  defp provider_retry_ms(%ProviderResult{rate_limit: rate_limit}, now) do
    retry_after_ms(rate_limit[:retry_after]) || reset_delay_ms(rate_limit[:reset_at], now)
  end

  defp provider_retry_ms(_result, _now), do: nil

  defp retry_after_ms(seconds) when is_integer(seconds) and seconds > 0 do
    seconds
    |> Kernel.*(1_000)
    |> min(@maximum_provider_retry_ms)
    |> max(@minimum_retry_ms)
  end

  defp retry_after_ms(_seconds), do: nil

  defp reset_delay_ms(%DateTime{} = reset_at, %DateTime{} = now) do
    reset_at
    |> DateTime.diff(now, :millisecond)
    |> bounded_future_delay()
  end

  defp reset_delay_ms(seconds, %DateTime{} = now) when is_integer(seconds) and seconds > 0 do
    seconds
    |> DateTime.from_unix()
    |> case do
      {:ok, reset_at} -> reset_delay_ms(reset_at, now)
      _ -> nil
    end
  end

  defp reset_delay_ms(_reset_at, _now), do: nil

  defp bounded_future_delay(delay) when delay > 0,
    do: delay |> min(@maximum_provider_retry_ms) |> max(@minimum_retry_ms)

  defp bounded_future_delay(_delay), do: nil

  defp topic(kind, key) do
    encoded = key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
    "build_order:graph:" <> kind <> ":" <> encoded
  end
end
