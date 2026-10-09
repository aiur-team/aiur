defmodule Aiur.BuildQueue.Planner do
  @moduledoc """
  Pure desired-versus-observed queue reconciliation. No actions are executed.

  Observations and claims are keyed by issue ID; other records are lists.
  Options require `:label_prefix` and `:observation_max_age_ms`, and accept
  Readiness's `:not_planned` policy and `:promote_parked?` (default false).
  `:withdrawal_holds` is a MapSet of IDs whose runtime dispatch hold has been
  installed before probing claims. Missing/unavailable claims never withdraw.
  `:priorities` and `:created_at` are optional maps used for start order.

  Item projections contain `issue_id`, `state`, `reason`, `verdict`, and `rank`.
  Item actions are `{verb, issue_id}`; attention actions are `{verb, latch_key}`.
  The executor persists provenance, intents and latches before reconciling again.
  """
  alias Aiur.BuildQueue.Model.Observation
  alias Aiur.BuildQueue.{Ordering, PlannerPolicy, Readiness}

  defmodule Input do
    @moduledoc "Immutable queue records and transient reconciliation evidence."
    @enforce_keys [:now_ms, :opts]
    defstruct queues: [], items: [], edges: [], observations: %{}, intents: [], latches: [], claims: :unavailable, now_ms: nil, opts: []
    @type t :: %__MODULE__{queues: list(), items: list(), edges: list(), observations: map(), intents: list(), latches: list(), claims: map() | :unavailable, now_ms: integer(), opts: keyword()}
  end

  @type item_state :: %{issue_id: String.t(), state: atom(), reason: term(), verdict: Readiness.item_verdict(), rank: tuple()}
  @type action :: {atom(), String.t() | {term(), term()}}

  @spec plan(Input.t()) :: {[item_state()], [action()]}
  def plan(%Input{} = input) do
    context = context(input)
    pairs = Enum.map(input.items, &project(&1, context)) |> Enum.sort_by(fn {state, _actions} -> state.rank end)
    {states, actions} = Enum.unzip(pairs)
    actions = Enum.concat(actions)
    context = Map.put(context, :promotions, for({:promote, id} <- actions, do: id))
    {states, actions ++ attention_actions(states, context)}
  end

  defp context(input) do
    cycles = Readiness.cyclic_items(input.edges)
    opts = Keyword.merge(input.opts, now_ms: input.now_ms, max_age_ms: Keyword.fetch!(input.opts, :observation_max_age_ms))
    open = for item <- input.items, match?(%Observation{open?: true}, input.observations[item.issue_id]), member?(input.observations[item.issue_id], opts), do: item.issue_id

    %{input: input, opts: opts, cycles: cycles, edges: Enum.group_by(input.edges, & &1.dependent), queues: Map.new(input.queues, &{&1.id, &1}), downstream: Ordering.downstream_open(input.edges, open)}
  end

  defp project(item, context) do
    observation = context.input.observations[item.issue_id]
    verdict = Map.get(Keyword.get(context.opts, :source_verdicts, %{}), item.issue_id, verdict(item.issue_id, context))
    {state, reason, actions} = PlannerPolicy.decide(item, observation, verdict, context)
    priority = context.opts |> Keyword.get(:priorities, %{}) |> Map.get(item.issue_id, 5)
    created = context.opts |> Keyword.get(:created_at, %{}) |> Map.get(item.issue_id)
    rank = Ordering.rank(item, Map.get(context.downstream, item.issue_id, 0), priority, created)
    {%{issue_id: item.issue_id, state: state, reason: reason, verdict: verdict, rank: rank}, actions}
  end

  defp verdict(_id, %{cycles: {:unknown, cause}}), do: {:unknown, [cause]}

  defp verdict(id, context) do
    if MapSet.member?(context.cycles, id) do
      {:unknown, [:cyclic]}
    else
      context.edges |> Map.get(id, []) |> Enum.map(&edge_verdict(&1, context)) |> Readiness.item_verdict()
    end
  end

  defp edge_verdict(_edge, %{cycles: {:unknown, cause}}), do: {:unknown, cause}

  defp edge_verdict(edge, context) do
    opts = Keyword.put(context.opts, :cyclic, MapSet.member?(context.cycles, edge.prerequisite))

    case Map.get(Keyword.get(opts, :source_verdicts, %{}), edge.prerequisite) do
      {:unknown, [reason | _]} -> {:unknown, reason}
      _ -> Readiness.edge_verdict(context.input.observations[edge.prerequisite], opts)
    end
  end

  defp attention_actions(states, context) do
    desired = states |> Enum.flat_map(&(attention_keys(&1, context) ++ failed_keys(&1, context))) |> MapSet.new()
    existing = context.input.latches |> Enum.map(& &1.key) |> Enum.filter(&owned_latch?/1) |> MapSet.new()
    desired = MapSet.union(desired, retained_latches(existing, states, context))
    pending = MapSet.new(context.input.latches |> Enum.filter(&(not &1.emitted? and match?({:promoted_unauthorized, _}, &1.key))), & &1.key)
    opens = desired |> MapSet.difference(MapSet.difference(existing, pending)) |> Enum.sort() |> Enum.map(&{:attention_open, &1})
    resolves = existing |> MapSet.difference(desired) |> Enum.sort() |> Enum.map(&{:attention_resolve, &1})
    opens ++ resolves
  end

  defp owned_latch?({cause, _id}) when cause in [:promoted_unauthorized, :dependency_changed_after_start], do: true
  defp owned_latch?({{:prerequisite_failed, _cause}, _id}), do: true
  defp owned_latch?(_key), do: false

  defp retained_latches(existing, states, context) do
    active = for state <- states, state.state not in [:removed, :completed, :cancelled], do: state.issue_id
    unknown = for edge <- context.input.edges, edge.dependent in active, match?({:unknown, _}, edge_verdict(edge, context)), do: edge.prerequisite

    existing
    |> Enum.filter(fn
      {{:prerequisite_failed, _cause}, id} -> id in unknown
      _key -> false
    end)
    |> MapSet.new()
  end

  # Latch a known decline after its planned promotion, so applied effects converge.
  defp attention_keys(%{state: :ready, issue_id: id}, context) do
    if id in context.promotions and is_map(context.input.claims) and context.input.claims[id] == {:declined, :unauthorized}, do: [{:promoted_unauthorized, id}], else: []
  end

  defp attention_keys(%{state: :promoted_unauthorized, issue_id: id}, _context), do: [{:promoted_unauthorized, id}]

  defp attention_keys(%{state: :claimed, verdict: verdict, issue_id: id}, context) when verdict != :ready do
    if Enum.any?(context.input.items, &(&1.issue_id == id and &1.promoted_at != nil)), do: [{:dependency_changed_after_start, id}], else: []
  end

  defp attention_keys(_state, _context), do: []

  defp failed_keys(%{state: state}, _context) when state in [:removed, :completed, :cancelled], do: []

  defp failed_keys(%{issue_id: id}, context) do
    for edge <- Map.get(context.edges, id, []),
        match?({:failed, _}, edge_verdict(edge, context)) or edge_verdict(edge, context) == {:unknown, :duplicate},
        do: {{:prerequisite_failed, elem(edge_verdict(edge, context), 1)}, edge.prerequisite}
  end

  defp member?(nil, _opts), do: false
  defp member?(observation, opts), do: "#{Keyword.fetch!(opts, :label_prefix)}:queued" in observation.labels
end
