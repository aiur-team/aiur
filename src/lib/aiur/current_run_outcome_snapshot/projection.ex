defmodule Aiur.CurrentRunOutcomeSnapshot.Projection do
  @moduledoc false

  alias Aiur.CurrentRunOutcomeSnapshot.{MembershipIndex, Outcomes, SourceState}
  alias Aiur.CurrentRunProjection.Value

  @spec snapshot(map()) :: map()
  def snapshot(inputs) when is_map(inputs) do
    run = Value.get(inputs, :run)
    membership = Value.get(inputs, :membership)
    recent_merges = Value.get(inputs, :recent_merges)
    repository = inputs |> Value.get(:configured_repository) |> SourceState.normalize_repository()
    input_merges = recent_merges |> Value.get(:merges, []) |> List.wrap()
    members = membership |> Value.get(:members, []) |> List.wrap()
    index = membership_index(inputs, members)
    limit = normalize_limit(Value.get(inputs, :limit, 100))
    source_state = SourceState.evaluate(run, membership, recent_merges, repository)

    context = %{
      inputs: inputs,
      run: run,
      membership: membership,
      recent_merges: recent_merges,
      repository: repository,
      input_merges: input_merges,
      index: index,
      limit: limit,
      source_state: source_state
    }

    if source_state.unavailable? do
      unavailable_snapshot(context)
    else
      available_snapshot(context)
    end
  end

  def snapshot(_inputs), do: snapshot(%{})

  @spec membership_signature([map() | Aiur.TrackerIdentity.t()]) :: String.t()
  defdelegate membership_signature(members), to: MembershipIndex, as: :signature

  defp available_snapshot(%{repository: {:ok, repository}} = context) do
    result =
      Outcomes.build(
        context.input_merges,
        context.index,
        repository,
        context.run,
        context.membership,
        context.limit
      )

    source_state =
      context.source_state
      |> maybe_partial(result.invalid_count > 0, :invalid_merge_entries)
      |> maybe_partial(result.truncated?, :result_truncated)

    state = SourceState.public_state(source_state, result.outcomes)

    %{
      version: Aiur.CurrentRunOutcomeSnapshot.version(),
      generation: Value.get(context.inputs, :generation, 0),
      state: state,
      completeness: SourceState.completeness(source_state),
      run: SourceState.public_run(context.run),
      repository: SourceState.repository_name(repository),
      membership: membership_descriptor(context.membership, context.index),
      outcomes: result.outcomes,
      counts: %{
        input: length(context.input_merges),
        invalid: result.invalid_count,
        deduplicated: result.deduplicated_count,
        qualified: result.qualified_count,
        returned: length(result.outcomes)
      },
      exclusions: result.exclusions,
      limit: context.limit,
      truncated?: result.truncated?,
      health: %{status: SourceState.health(state), reasons: source_state.reasons},
      freshness: %{status: source_state.freshness},
      sources: SourceState.provenance(context.membership, context.recent_merges, source_state)
    }
  end

  defp unavailable_snapshot(context) do
    %{
      version: Aiur.CurrentRunOutcomeSnapshot.version(),
      generation: Value.get(context.inputs, :generation, 0),
      state: :unavailable,
      completeness: :unavailable,
      run: SourceState.public_run(context.run),
      repository: SourceState.configured_repository_name(context.repository),
      membership: membership_descriptor(context.membership, context.index),
      outcomes: [],
      counts: %{input: length(context.input_merges), invalid: 0, deduplicated: 0, qualified: 0, returned: 0},
      exclusions: Outcomes.empty_exclusions(),
      limit: context.limit,
      truncated?: false,
      health: %{status: :unavailable, reasons: context.source_state.reasons},
      freshness: %{status: context.source_state.freshness},
      sources: SourceState.provenance(context.membership, context.recent_merges, context.source_state)
    }
  end

  defp membership_descriptor(membership, index) do
    %{generation: Value.get(membership, :generation, nil), signature: index.signature}
  end

  defp membership_index(inputs, members) do
    case Value.get(inputs, :membership_index, nil) do
      %{by_locator: by_locator, signature: signature} = index
      when is_map(by_locator) and is_binary(signature) ->
        index

      _index ->
        MembershipIndex.build(members)
    end
  end

  defp maybe_partial(state, true, reason), do: SourceState.add_partial(state, reason)
  defp maybe_partial(state, false, _reason), do: state
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 100)
  defp normalize_limit(_limit), do: 100
end
