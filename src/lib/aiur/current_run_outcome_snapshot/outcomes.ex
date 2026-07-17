defmodule Aiur.CurrentRunOutcomeSnapshot.Outcomes do
  @moduledoc false

  alias Aiur.CurrentRunOutcomeSnapshot.{MembershipIndex, SourceState}
  alias Aiur.CurrentRunProjection.Value
  alias Aiur.{RecentMerge, TicketBranch}

  @exclusion_reasons [
    :repository_mismatch,
    :noncanonical_branch,
    :outside_run_window,
    :not_current_member,
    :ambiguous_identity
  ]

  @spec build([term()], MembershipIndex.t(), tuple(), map(), map(), pos_integer()) :: map()
  def build(input_merges, index, repository, run, membership, limit) do
    {merges, invalid_count} = deduplicate(input_merges)

    {qualified, exclusions} =
      Enum.reduce(merges, {[], empty_exclusions()}, fn merge, {outcomes, reasons} ->
        case qualify(merge, repository, run, index) do
          {:ok, identity} -> {[outcome(merge, identity, run, membership) | outcomes], reasons}
          {:error, reason} -> {outcomes, Map.update!(reasons, reason, &(&1 + 1))}
        end
      end)

    qualified = sort(qualified)
    returned = Enum.take(qualified, limit)

    %{
      outcomes: returned,
      exclusions: exclusions,
      invalid_count: invalid_count,
      deduplicated_count: length(merges),
      qualified_count: length(qualified),
      truncated?: length(qualified) > limit
    }
  end

  @spec empty_exclusions() :: map()
  def empty_exclusions, do: Map.new(@exclusion_reasons, &{&1, 0})

  defp qualify(%RecentMerge{} = merge, repository, run, index) do
    with :ok <- matching_repository(merge.repository, repository),
         {:ok, locator} <- canonical_locator(merge.head_ref),
         :ok <- inside_window(merge.merged_at, run) do
      MembershipIndex.lookup(index, locator, repository)
    end
  end

  defp matching_repository(value, repository) do
    with {:ok, candidate} <- SourceState.normalize_repository_name(value),
         true <- SourceState.same_repository?(candidate, repository) do
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
      DateTime.compare(merged_at, Value.get(run, :started_at)) != :lt and
        DateTime.compare(merged_at, Value.get(run, :observed_at)) != :gt

    if inside?, do: :ok, else: {:error, :outside_run_window}
  end

  defp inside_window(_merged_at, _run), do: {:error, :outside_run_window}

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
        id: Value.get(run, :id),
        started_at: Value.get(run, :started_at),
        observed_at: Value.get(run, :observed_at),
        membership_generation: Value.get(membership, :generation)
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
      |> Enum.reduce(%{}, fn merge, by_id -> Map.update(by_id, merge.id, merge, &enrich(&1, merge)) end)
      |> Map.values()

    {deduplicated, length(invalid)}
  end

  defp enrich(existing, incoming) do
    case RecentMerge.enrich(existing, incoming) do
      {:accepted, enriched} -> enriched
      {:duplicate, retained} -> retained
    end
  end

  defp observation_order(%RecentMerge{last_observed_at: %DateTime{} = observed_at}),
    do: {DateTime.to_unix(observed_at, :microsecond)}

  defp observation_order(_merge), do: {0}

  defp sort(outcomes) do
    Enum.sort(outcomes, fn left, right ->
      case DateTime.compare(left.merged_at, right.merged_at) do
        :gt -> true
        :lt -> false
        :eq -> left.id <= right.id
      end
    end)
  end
end
