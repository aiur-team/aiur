defmodule Aiur.CurrentRunOutcomeSnapshot.Projection do
  @moduledoc false

  alias Aiur.{RecentMerge, TicketBranch, TrackerIdentity}

  @exclusion_reasons [
    :repository_mismatch,
    :noncanonical_branch,
    :outside_run_window,
    :not_current_member,
    :ambiguous_identity
  ]

  @spec snapshot(map()) :: map()
  def snapshot(inputs) when is_map(inputs) do
    run = map_value(inputs, :run)
    membership = map_value(inputs, :membership)
    recent_merges = map_value(inputs, :recent_merges)
    repository = normalize_configured_repository(map_value(inputs, :configured_repository))
    limit = normalize_limit(map_value(inputs, :limit, 100))
    source_state = source_state(run, membership, recent_merges, repository)
    input_merges = recent_merges |> map_value(:merges, []) |> List.wrap()

    if source_state.unavailable? do
      unavailable_snapshot(
        inputs,
        run,
        membership,
        recent_merges,
        repository,
        limit,
        input_merges,
        source_state
      )
    else
      project_available(
        inputs,
        run,
        membership,
        recent_merges,
        repository,
        limit,
        input_merges,
        source_state
      )
    end
  end

  def snapshot(_inputs), do: snapshot(%{})

  @spec membership_signature([map() | TrackerIdentity.t()]) :: String.t()
  def membership_signature(members) when is_list(members) do
    members
    |> Enum.map(&member_identity/1)
    |> Enum.map(&identity_signature/1)
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def membership_signature(_members), do: membership_signature([])

  defp project_available(
         inputs,
         run,
         membership,
         recent_merges,
         {:ok, repository},
         limit,
         input_merges,
         source_state
       ) do
    members = membership |> map_value(:members, []) |> List.wrap()
    {merges, invalid_count} = deduplicate(input_merges)

    {qualified, exclusions} =
      Enum.reduce(merges, {[], empty_exclusions()}, fn merge, {outcomes, reasons} ->
        case qualify(merge, repository, run, members) do
          {:ok, identity} ->
            {[outcome(merge, identity, run, membership) | outcomes], reasons}

          {:error, reason} ->
            {outcomes, Map.update!(reasons, reason, &(&1 + 1))}
        end
      end)

    qualified = sort_outcomes(qualified)
    returned = Enum.take(qualified, limit)
    truncated? = length(qualified) > limit

    source_state =
      source_state
      |> maybe_add_partial(invalid_count > 0, :invalid_merge_entries)
      |> maybe_add_partial(truncated?, :result_truncated)

    state = public_state(source_state, returned)

    %{
      version: Aiur.CurrentRunOutcomeSnapshot.version(),
      generation: map_value(inputs, :generation, 0),
      state: state,
      completeness: completeness(source_state),
      run: public_run(run),
      repository: repository_name(repository),
      membership: %{
        generation: map_value(membership, :generation),
        signature: membership_signature(members)
      },
      outcomes: returned,
      counts: %{
        input: length(input_merges),
        invalid: invalid_count,
        deduplicated: length(merges),
        qualified: length(qualified),
        returned: length(returned)
      },
      exclusions: exclusions,
      limit: limit,
      truncated?: truncated?,
      health: %{status: health_status(state), reasons: source_state.reasons},
      freshness: %{status: source_state.freshness},
      sources: source_provenance(membership, recent_merges, source_state)
    }
  end

  defp unavailable_snapshot(
         inputs,
         run,
         membership,
         recent_merges,
         repository,
         limit,
         input_merges,
         source_state
       ) do
    members = membership |> map_value(:members, []) |> List.wrap()

    %{
      version: Aiur.CurrentRunOutcomeSnapshot.version(),
      generation: map_value(inputs, :generation, 0),
      state: :unavailable,
      completeness: :unavailable,
      run: public_run(run),
      repository: configured_repository_name(repository),
      membership: %{
        generation: map_value(membership, :generation),
        signature: membership_signature(members)
      },
      outcomes: [],
      counts: %{
        input: length(input_merges),
        invalid: 0,
        deduplicated: 0,
        qualified: 0,
        returned: 0
      },
      exclusions: empty_exclusions(),
      limit: limit,
      truncated?: false,
      health: %{status: :unavailable, reasons: source_state.reasons},
      freshness: %{status: source_state.freshness},
      sources: source_provenance(membership, recent_merges, source_state)
    }
  end

  defp source_state(run, membership, recent_merges, repository) do
    run_valid? = valid_run?(run)

    facts = %{
      run_valid?: run_valid?,
      run_matches?: run_valid? and map_value(membership, :run_id) == map_value(run, :id),
      repository_available?: match?({:ok, _repository}, repository),
      membership_health: membership |> map_value(:health) |> health_status_value(),
      membership_truncated?: map_value(membership, :truncated?, false) == true,
      merge_health: recent_merges |> map_value(:health) |> merge_health(),
      reconciliation:
        recent_merges
        |> map_value(:reconciliation)
        |> map_value(:status, :unknown),
      freshness: membership |> map_value(:freshness) |> freshness_status()
    }

    %{
      unavailable?: unavailable_sources?(facts),
      partial?: partial_sources?(facts),
      freshness: facts.freshness,
      reasons: source_reasons(facts)
    }
  end

  defp unavailable_sources?(facts) do
    not facts.run_valid? or not facts.run_matches? or not facts.repository_available? or
      facts.membership_health == :unavailable or facts.merge_health == :unavailable
  end

  defp partial_sources?(facts) do
    facts.membership_health == :degraded or facts.membership_truncated? or
      facts.merge_health == :degraded or facts.reconciliation != :complete or
      facts.freshness != :fresh
  end

  defp source_reasons(facts) do
    []
    |> maybe_reason(not facts.run_valid?, :invalid_run_window)
    |> maybe_reason(facts.run_valid? and not facts.run_matches?, :run_membership_mismatch)
    |> maybe_reason(not facts.repository_available?, :configured_repository_unavailable)
    |> maybe_reason(facts.membership_health == :unavailable, :membership_unavailable)
    |> maybe_reason(facts.merge_health == :unavailable, :merge_source_unavailable)
    |> maybe_reason(facts.membership_health == :degraded, :membership_degraded)
    |> maybe_reason(facts.membership_truncated?, :membership_truncated)
    |> maybe_reason(facts.merge_health == :degraded, :merge_source_degraded)
    |> maybe_reason(facts.reconciliation != :complete, :reconciliation_incomplete)
    |> membership_freshness_reason(facts.freshness)
  end

  defp membership_freshness_reason(reasons, :fresh), do: reasons
  defp membership_freshness_reason(reasons, :stale), do: reasons ++ [:membership_stale]
  defp membership_freshness_reason(reasons, :unknown), do: reasons ++ [:membership_freshness_unknown]

  defp membership_freshness_reason(reasons, :unavailable),
    do: reasons ++ [:membership_freshness_unavailable]

  defp membership_freshness_reason(reasons, :partial),
    do: reasons ++ [:membership_freshness_partial]

  defp add_partial(state, reason) do
    %{state | partial?: true, reasons: Enum.uniq(state.reasons ++ [reason])}
  end

  defp maybe_add_partial(state, true, reason), do: add_partial(state, reason)
  defp maybe_add_partial(state, false, _reason), do: state

  defp valid_run?(run) when is_map(run) do
    id = map_value(run, :id)
    started_at = map_value(run, :started_at)
    observed_at = map_value(run, :observed_at)

    map_value(run, :valid?, true) == true and is_binary(id) and String.trim(id) != "" and
      is_struct(started_at, DateTime) and is_struct(observed_at, DateTime) and
      DateTime.compare(observed_at, started_at) != :lt
  end

  defp valid_run?(_run), do: false

  defp qualify(%RecentMerge{} = merge, repository, run, members) do
    with :ok <- matching_repository(merge.repository, repository),
         {:ok, locator} <- canonical_locator(merge.head_ref),
         :ok <- inside_window(merge.merged_at, run) do
      unique_member(locator, repository, members)
    end
  end

  defp matching_repository(value, repository) do
    with {:ok, candidate} <- normalize_repository_name(value),
         true <- same_repository?(candidate, repository) do
      :ok
    else
      _mismatch -> {:error, :repository_mismatch}
    end
  end

  defp canonical_locator(head_ref) do
    case TicketBranch.ticket_id(head_ref) do
      nil -> {:error, :noncanonical_branch}
      locator -> {:ok, locator}
    end
  end

  defp inside_window(%DateTime{} = merged_at, run) do
    inside? =
      DateTime.compare(merged_at, map_value(run, :started_at)) != :lt and
        DateTime.compare(merged_at, map_value(run, :observed_at)) != :gt

    if inside?, do: :ok, else: {:error, :outside_run_window}
  end

  defp inside_window(_merged_at, _run), do: {:error, :outside_run_window}

  defp unique_member(locator, repository, members) do
    matches =
      members
      |> Enum.map(&member_identity/1)
      |> Enum.filter(fn
        %TrackerIdentity{} = identity ->
          TrackerIdentity.joinable?(identity) and identity.identifier == locator and
            same_repository?({identity.owner, identity.repository}, repository)

        _identity ->
          false
      end)

    case matches do
      [identity] -> {:ok, identity}
      [] -> {:error, :not_current_member}
      _many -> {:error, :ambiguous_identity}
    end
  end

  defp outcome(merge, identity, run, membership) do
    %{
      id: merge.id,
      repository: merge.repository,
      number: merge.number,
      title: merge.title,
      summary: merge.summary,
      url: merge.url,
      head_ref: merge.head_ref,
      head_sha: merge.head_sha,
      merge_commit_sha: merge.merge_commit_sha,
      merged_at: merge.merged_at,
      member: %{identity: identity, identifier: identity.identifier},
      association: %{
        version: 1,
        basis: :configured_repository_branch_locator_unique_membership_run_window
      },
      run: %{
        id: map_value(run, :id),
        started_at: map_value(run, :started_at),
        observed_at: map_value(run, :observed_at),
        membership_generation: map_value(membership, :generation)
      },
      observation: %{
        source: merge.observation_source,
        backfilled?: merge.backfilled?,
        live_observed?: merge.live_observed?,
        observed_run_id: merge.observed_run_id,
        first_observed_at: merge.first_observed_at,
        last_observed_at: merge.last_observed_at
      }
    }
  end

  defp deduplicate(merges) do
    {valid, invalid} = Enum.split_with(merges, &is_struct(&1, RecentMerge))

    deduplicated =
      valid
      |> Enum.sort_by(&observation_order/1)
      |> Enum.reduce(%{}, fn merge, by_id ->
        Map.update(by_id, merge.id, merge, &enrich_merge(&1, merge))
      end)
      |> Map.values()

    {deduplicated, length(invalid)}
  end

  defp enrich_merge(existing, incoming) do
    case RecentMerge.enrich(existing, incoming) do
      {:accepted, enriched} -> enriched
      {:duplicate, retained} -> retained
    end
  end

  defp observation_order(%RecentMerge{last_observed_at: %DateTime{} = observed_at}) do
    {DateTime.to_unix(observed_at, :microsecond)}
  end

  defp observation_order(_merge), do: {0}

  defp sort_outcomes(outcomes) do
    Enum.sort(outcomes, fn left, right ->
      case DateTime.compare(left.merged_at, right.merged_at) do
        :gt -> true
        :lt -> false
        :eq -> left.id <= right.id
      end
    end)
  end

  defp public_state(%{unavailable?: true}, _outcomes), do: :unavailable
  defp public_state(%{freshness: :stale}, _outcomes), do: :stale
  defp public_state(%{partial?: true}, _outcomes), do: :partial
  defp public_state(_source_state, []), do: :healthy_empty
  defp public_state(_source_state, _outcomes), do: :healthy

  defp completeness(%{unavailable?: true}), do: :unavailable
  defp completeness(%{partial?: true}), do: :partial
  defp completeness(%{freshness: :stale}), do: :partial
  defp completeness(_source_state), do: :complete

  defp health_status(:unavailable), do: :unavailable
  defp health_status(state) when state in [:partial, :stale], do: :partial
  defp health_status(_state), do: :healthy

  defp health_status_value(status) when status in [:healthy, :available, :writable],
    do: :healthy

  defp health_status_value(status) when status in [:degraded, :partial, :stale, :unknown],
    do: :degraded

  defp health_status_value({:degraded, _reason}), do: :degraded
  defp health_status_value({:unavailable, _reason}), do: :unavailable
  defp health_status_value(%{status: status}), do: health_status_value(status)
  defp health_status_value(_status), do: :unavailable

  defp merge_health(:writable), do: :healthy
  defp merge_health({:unavailable, _reason}), do: :unavailable
  defp merge_health({:corrupt, _line, _reason}), do: :degraded
  defp merge_health({_reason, _detail}), do: :degraded
  defp merge_health(_health), do: :unavailable

  defp freshness_status(%{status: status}), do: freshness_status(status)

  defp freshness_status(status)
       when status in [:fresh, :stale, :unknown, :unavailable, :partial],
       do: status

  defp freshness_status(_status), do: :unknown

  defp normalize_configured_repository({:ok, repository}), do: normalize_repository(repository)
  defp normalize_configured_repository(repository), do: normalize_repository(repository)

  defp normalize_repository({owner, repository})
       when is_binary(owner) and is_binary(repository) do
    owner = String.trim(owner)
    repository = String.trim(repository)

    if owner != "" and repository != "" and not String.contains?(owner, "/") and
         not String.contains?(repository, "/") do
      {:ok, {owner, repository}}
    else
      {:error, :invalid_configured_repository}
    end
  end

  defp normalize_repository({:error, reason}), do: {:error, reason}
  defp normalize_repository(_repository), do: {:error, :invalid_configured_repository}

  defp normalize_repository_name(value) when is_binary(value) do
    case String.split(String.trim(value), "/", parts: 2) do
      [owner, repository] -> normalize_repository({owner, repository})
      _parts -> {:error, :invalid_repository}
    end
  end

  defp normalize_repository_name(_value), do: {:error, :invalid_repository}

  defp same_repository?({left_owner, left_repo}, {right_owner, right_repo}) do
    String.downcase(left_owner) == String.downcase(right_owner) and
      String.downcase(left_repo) == String.downcase(right_repo)
  end

  defp repository_name({owner, repository}), do: "#{owner}/#{repository}"
  defp configured_repository_name({:ok, repository}), do: repository_name(repository)
  defp configured_repository_name({:error, _reason}), do: nil

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 100)
  defp normalize_limit(_limit), do: 100

  defp member_identity(%TrackerIdentity{} = identity), do: identity
  defp member_identity(%{identity: identity}), do: identity
  defp member_identity(%{tracker_identity: identity}), do: identity
  defp member_identity(_member), do: nil

  defp identity_signature(%TrackerIdentity{} = identity) do
    TrackerIdentity.github_key(identity) ||
      {:unjoinable, identity.kind, identity.owner, identity.repository, identity.identifier, identity.reason}
  end

  defp identity_signature(_identity), do: {:unjoinable, nil}

  defp public_run(run) do
    %{
      id: map_value(run, :id),
      started_at: map_value(run, :started_at),
      observed_at: map_value(run, :observed_at)
    }
  end

  defp source_provenance(membership, recent_merges, source_state) do
    %{
      run_generation: nil,
      membership_generation: map_value(membership, :generation),
      membership_health: membership |> map_value(:health) |> health_status_value(),
      membership_freshness: source_state.freshness,
      merge_generation: map_value(recent_merges, :generation),
      merge_health: recent_merges |> map_value(:health) |> merge_health(),
      configured_repository_generation: nil,
      reconciliation: recent_merges |> map_value(:reconciliation) |> safe_reconciliation()
    }
  end

  defp safe_reconciliation(reconciliation) when is_map(reconciliation) do
    %{
      status: map_value(reconciliation, :status, :unknown),
      partial?: map_value(reconciliation, :partial?),
      pages_fetched: map_value(reconciliation, :pages_fetched, 0)
    }
  end

  defp safe_reconciliation(_reconciliation) do
    %{status: :unknown, partial?: nil, pages_fetched: 0}
  end

  defp empty_exclusions, do: Map.new(@exclusion_reasons, &{&1, 0})
  defp maybe_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_reason(reasons, false, _reason), do: reasons

  defp map_value(map, key, default \\ %{})

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_value(_map, _key, default), do: default
end
