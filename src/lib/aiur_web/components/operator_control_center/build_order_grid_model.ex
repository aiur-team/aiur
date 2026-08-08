defmodule AiurWeb.OperatorControlCenter.BuildOrderGridModel do
  @moduledoc """
  Pure projection of a Build Order view model into the spatial grid the dashboard
  renders: epic **columns**, execution-wave **rows**,
  small ticket **cards** placed in the (epic, wave) cells, and dependency
  **edges** between cards.

  All derivation is pure and total so it is unit-testable without a live
  provider. Every pack member participates in its assigned lane, phase,
  dependencies, and complexity-weighted completion.
  """

  alias Aiur.BuildOrder.Metadata
  alias AiurWeb.BuildOrderViewModel.{Edge, Node}
  alias AiurWeb.OperatorControlCenter.BuildOrderEpicIcon

  @type card :: %{
          id: String.t(),
          key: term(),
          identity: term() | nil,
          lane: String.t(),
          phase: pos_integer() | :unphased,
          complexity: pos_integer() | nil,
          title: String.t(),
          progress: 0..100,
          has_progress: boolean(),
          completion_known: boolean(),
          merged: boolean(),
          state: :merged | :working | :ready | :blocked | :plain | :planned,
          status_word: String.t(),
          icon: String.t() | nil,
          blocks: non_neg_integer(),
          discovered?: boolean(),
          added_at: DateTime.t() | nil
        }

  @type column :: %{
          lane: String.t(),
          label: String.t(),
          count: non_neg_integer(),
          pct: 0..100 | nil,
          core?: boolean()
        }

  @doc """
  Builds the grid projection. `model` is a `BuildOrderViewModel` (or nil).
  """
  @spec build(term()) :: %{
          columns: [column()],
          waves: [map()],
          cards: [card()],
          edges: [map()],
          overall_pct: 0..100 | nil,
          totals: %{baseline_total: non_neg_integer(), discovered_total: non_neg_integer(), total: non_neg_integer(), completed: non_neg_integer()},
          planning?: boolean()
        }
  def build(model) do
    planning? = planning?(model)
    member_cards = member_cards(model, planning?)
    edges = edges(model, member_cards, planning?)
    cards = annotate_blocks(member_cards, edges)

    %{
      columns: columns(cards),
      waves: waves(cards),
      cards: cards,
      edges: edges,
      overall_pct: completion_percent(cards),
      totals: totals(cards),
      planning?: planning?
    }
  end

  # Edges are blocker → blocked, so a card "blocks" every distinct ticket that
  # depends on it: the count of edges where the card is the source.
  defp annotate_blocks(cards, edges) do
    blocks =
      edges
      |> Enum.group_by(& &1.source, & &1.target)
      |> Map.new(fn {source, targets} -> {source, targets |> Enum.uniq() |> length()} end)

    Enum.map(cards, fn card -> Map.put(card, :blocks, Map.get(blocks, card.id, 0)) end)
  end

  defp planning?(%AiurWeb.BuildOrderViewModel{planning?: planning?}), do: planning? == true
  defp planning?(_model), do: false

  # --- cards ------------------------------------------------------------------

  defp member_cards(%AiurWeb.BuildOrderViewModel{nodes: nodes}, planning?) when is_list(nodes),
    do: Enum.map(nodes, &core_card(&1, planning? or Map.get(&1.card, :planned?) == true))

  defp member_cards(_model, _planning?), do: []

  # In planning (pre-ticket) mode a ticket is neither merged nor blocked — it is
  # simply planned, with no live progress; dependencies are drawn neutrally.
  defp core_card(%Node{} = node, true) do
    node
    |> core_card(false)
    |> Map.merge(%{
      progress: 0,
      has_progress: false,
      completion_known: true,
      merged: false,
      state: :planned,
      status_word: "planned"
    })
  end

  defp core_card(%Node{card: card} = node, false) do
    status_key = status_key(node)
    merged = status_key == :status_completed
    complexity = complexity(node)
    progress = progress(merged, Map.get(card, :progress))

    %{
      id: identifier(card),
      key: node.key,
      identity: node.identity,
      lane: lane(Map.get(card, :lane)),
      phase: phase(Map.get(card, :phase)),
      complexity: complexity,
      title: title(node),
      progress: progress,
      has_progress: merged or is_integer(Map.get(card, :progress)),
      completion_known: completion_known?(merged, Map.get(card, :progress), Map.get(card, :lifecycle)),
      merged: merged,
      state: core_state(status_key),
      status_word: core_status_word(status_key, node.execution, Map.get(card, :status_text)),
      icon: Map.get(card, :icon),
      discovered?: Map.get(card, :provenance) == :discovered,
      added_at: Map.get(card, :added_at)
    }
  end

  # --- columns (epics) --------------------------------------------------------

  defp columns(cards) do
    counts = Enum.frequencies_by(cards, & &1.lane)
    completion = completion_by(cards, :lane)
    order = cards |> Enum.map(& &1.lane) |> Enum.uniq()
    appearance = order |> Enum.with_index() |> Map.new()

    order
    |> Enum.sort_by(&lane_order(&1, appearance))
    |> Enum.map(fn lane ->
      %{
        lane: lane,
        label: BuildOrderEpicIcon.label(lane),
        count: Map.get(counts, lane, 0),
        pct: Map.get(completion, lane),
        core?: true
      }
    end)
  end

  # Built-in lanes keep their Metadata order; unknown lanes (e.g. a planning
  # pack's own epics) follow first-appearance order.
  defp lane_order(lane, appearance) do
    case Enum.find_index(Metadata.lanes(), &(&1 == lane)) do
      nil -> {1, Map.get(appearance, lane, 0)}
      index -> {0, index}
    end
  end

  # --- waves (rows) -----------------------------------------------------------

  defp waves(cards) do
    completion = wave_completion(cards)
    counts = Enum.frequencies_by(cards, & &1.phase)

    cards
    |> Enum.map(& &1.phase)
    |> Enum.uniq()
    |> Enum.sort_by(&wave_order/1)
    |> Enum.map(fn phase ->
      %{
        phase: phase,
        label: wave_label(phase),
        count: Map.get(counts, phase, 0),
        pct: Map.get(completion, phase)
      }
    end)
  end

  # Complexity-weighted completion per wave, over all pack members. A merged card
  # contributes its full weight; an in-flight card contributes its progress
  # fraction. If any card's completion is unknown, the aggregate stays unknown.
  # Weight is the card's complexity (points), defaulting to 1 when complexity is
  # unknown.
  defp wave_completion(cards), do: completion_by(cards, :phase)

  defp completion_by(cards, field) do
    cards
    |> Enum.group_by(&Map.fetch!(&1, field))
    |> Map.new(fn {value, grouped} -> {value, completion_percent(grouped)} end)
  end

  defp completion_percent(cards) do
    cards
    |> Enum.reduce_while({0, 0.0}, fn
      %{completion_known: false}, _acc ->
        {:halt, :unknown}

      card, {weight_acc, done_acc} ->
        weight = card.complexity || 1
        {:cont, {weight_acc + weight, done_acc + weight * completion_fraction(card)}}
    end)
    |> case do
      :unknown -> nil
      {0, _done} -> 0
      {weight, done} -> round(done / weight * 100)
    end
  end

  defp completion_fraction(%{merged: true}), do: 1.0
  defp completion_fraction(%{has_progress: true, progress: progress}), do: progress / 100
  defp completion_fraction(_card), do: 0.0

  defp completion_known?(true, _progress, _lifecycle), do: true
  defp completion_known?(false, progress, _lifecycle) when is_integer(progress), do: true
  defp completion_known?(false, _progress, %{state: state}) when state in [:open, :closed], do: true
  defp completion_known?(_merged, _progress, _lifecycle), do: false

  defp wave_order(:unphased), do: {1, 0}
  defp wave_order(phase) when is_integer(phase), do: {0, phase}

  defp wave_label(:unphased), do: "TBD"
  defp wave_label(phase) when is_integer(phase), do: "W#{phase}"

  # --- edges ------------------------------------------------------------------

  defp edges(%AiurWeb.BuildOrderViewModel{edges: edges}, core_cards, planning?) when is_list(edges) do
    id_by_key = Map.new(core_cards, &{&1.key, &1.id})
    planned_ids = core_cards |> Enum.filter(&(&1.state == :planned)) |> MapSet.new(& &1.id)

    edges
    |> Enum.flat_map(fn
      %Edge{source_key: source_key, target_key: target_key, state: state} ->
        with source when is_binary(source) <- Map.get(id_by_key, source_key),
             target when is_binary(target) <- Map.get(id_by_key, target_key) do
          [%{source: source, target: target, state: edge_state(state, planning? or MapSet.member?(planned_ids, source) or MapSet.member?(planned_ids, target))}]
        else
          _missing -> []
        end

      _other ->
        []
    end)
  end

  defp edges(_model, _core_cards, _planning?), do: []

  # Planning mode: every dependency is just a planned link (neutral), not a
  # cleared/blocking runtime edge.
  defp edge_state(_state, true), do: "planned"
  defp edge_state(:cleared, false), do: "cleared"
  defp edge_state("cleared", false), do: "cleared"
  defp edge_state(_state, false), do: "blocking"

  # --- shared field helpers ---------------------------------------------------

  defp status_key(%Node{status_icon: %{key: key}}), do: key
  defp status_key(_node), do: nil

  defp core_state(:status_completed), do: :merged
  defp core_state(:status_working), do: :working
  defp core_state(:status_ready), do: :ready
  defp core_state(key) when key in [:status_blocking, :status_terminal_unsatisfied, :status_cyclic], do: :blocked
  defp core_state(_key), do: :plain

  defp core_status_word(:status_completed, _execution, _text), do: "merged"
  defp core_status_word(:status_working, _execution, _text), do: "agent live"
  defp core_status_word(:status_ready, _execution, _text), do: "dependency-ready"
  defp core_status_word(:status_paused, %{pause_reason: :ci_wait}, _text), do: "CI waiting"
  defp core_status_word(:status_waiting, %{waiting_reason: :waiting_for_ci}, _text), do: "CI waiting"
  defp core_status_word(_key, _execution, text) when is_binary(text) and text != "", do: text
  defp core_status_word(_key, _execution, _text), do: "status unavailable"

  defp progress(true, _raw), do: 100
  defp progress(false, raw) when is_integer(raw) and raw in 0..100, do: raw
  defp progress(false, _raw), do: 0

  defp complexity(%Node{plan: %{complexity: complexity}}) when complexity in 1..5, do: complexity
  defp complexity(_node), do: nil

  defp lane(lane) when is_binary(lane) and lane != "", do: lane
  defp lane(_lane), do: "unassigned"

  defp phase(phase) when is_integer(phase) and phase > 0, do: phase
  defp phase(_phase), do: :unphased

  defp identifier(%{identifier: identifier}) when is_binary(identifier) and identifier != "",
    do: identifier

  defp identifier(_card), do: "Unknown ticket"

  defp title(%Node{title: title}) when is_binary(title) and title != "", do: title
  defp title(%Node{card: %{identifier: identifier}}), do: to_string(identifier)
  defp title(_node), do: "Untitled ticket"

  defp totals(cards) do
    {total, discovered_total, completed} =
      Enum.reduce(cards, {0, 0, 0}, fn card, {total, discovered_total, completed} ->
        {total + 1, discovered_total + if(card.discovered?, do: 1, else: 0), completed + if(card.merged, do: 1, else: 0)}
      end)

    %{
      baseline_total: total - discovered_total,
      discovered_total: discovered_total,
      total: total,
      completed: completed
    }
  end
end
