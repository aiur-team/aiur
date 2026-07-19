defmodule AiurWeb.OperatorControlCenter.BuildOrderGridModel do
  @moduledoc """
  Pure projection of a Build Order view model (plus the Ad Hoc overlay) into the
  spatial grid the dashboard renders: epic **columns**, execution-wave **rows**,
  small ticket **cards** placed in the (epic, wave) cells, and dependency
  **edges** between cards.

  All derivation is pure and total so it is unit-testable without a live
  provider. The core planning lanes and the Ad Hoc overlay are unified into one
  card shape; Ad Hoc is placed in its own column and never contributes to the
  core complexity-weighted wave completion (it is tracked separately).
  """

  alias Aiur.BuildOrder.Metadata
  alias AiurWeb.BuildOrderViewModel.{Edge, Node}
  alias AiurWeb.OperatorControlCenter.BuildOrderEpicIcon

  @adhoc_lane "adhoc"

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
          merged: boolean(),
          state: :merged | :working | :ready | :blocked | :plain,
          status_word: String.t(),
          adhoc: boolean()
        }

  @doc """
  Builds the grid projection. `model` is a `BuildOrderViewModel` (or nil);
  `adhoc` is the Ad Hoc overlay projection map (`%{rows: [...]}`) or nil.
  """
  @spec build(term(), term()) :: %{
          columns: [map()],
          waves: [map()],
          cards: [card()],
          edges: [map()]
        }
  def build(model, adhoc) do
    core_cards = core_cards(model)
    adhoc_cards = adhoc_cards(adhoc)
    cards = core_cards ++ adhoc_cards

    %{
      columns: columns(cards),
      waves: waves(core_cards, cards),
      cards: cards,
      edges: edges(model, core_cards)
    }
  end

  # --- cards ------------------------------------------------------------------

  defp core_cards(%AiurWeb.BuildOrderViewModel{nodes: nodes}) when is_list(nodes),
    do: Enum.map(nodes, &core_card/1)

  defp core_cards(_model), do: []

  defp core_card(%Node{card: card} = node) do
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
      merged: merged,
      state: core_state(status_key),
      status_word: core_status_word(status_key, Map.get(card, :status_text)),
      adhoc: false
    }
  end

  defp adhoc_cards(%{rows: rows}) when is_list(rows), do: Enum.map(rows, &adhoc_card/1)
  defp adhoc_cards(_adhoc), do: []

  defp adhoc_card(row) do
    merged = Map.get(row, :lifecycle) == :closed
    running = Map.get(row, :running?) == true
    raw_progress = Map.get(row, :progress)
    progress = progress(merged, raw_progress)

    state =
      cond do
        merged -> :merged
        running -> :working
        true -> :plain
      end

    %{
      id: to_string(Map.get(row, :identifier)),
      key: {:adhoc, Map.get(row, :identifier)},
      identity: nil,
      lane: @adhoc_lane,
      phase: phase(Map.get(row, :phase)),
      complexity: positive_complexity(Map.get(row, :complexity)),
      title: safe_title(Map.get(row, :title), to_string(Map.get(row, :identifier))),
      progress: progress,
      has_progress: merged or is_integer(raw_progress),
      merged: merged,
      state: state,
      status_word: adhoc_status_word(state),
      adhoc: true
    }
  end

  # --- columns (epics) --------------------------------------------------------

  defp columns(cards) do
    counts = Enum.frequencies_by(cards, & &1.lane)

    cards
    |> Enum.map(& &1.lane)
    |> Enum.uniq()
    |> Enum.sort_by(&lane_order/1)
    |> Enum.map(fn lane ->
      %{lane: lane, label: BuildOrderEpicIcon.label(lane), count: Map.get(counts, lane, 0)}
    end)
  end

  # Metadata lane order first, Ad Hoc last, unknown lanes in between.
  defp lane_order(@adhoc_lane), do: {2, 0, @adhoc_lane}

  defp lane_order(lane) do
    case Enum.find_index(Metadata.lanes(), &(&1 == lane)) do
      nil -> {1, 0, lane}
      index -> {0, index, lane}
    end
  end

  # --- waves (rows) -----------------------------------------------------------

  defp waves(core_cards, all_cards) do
    core_pct = wave_completion(core_cards)
    counts = Enum.frequencies_by(all_cards, & &1.phase)

    all_cards
    |> Enum.map(& &1.phase)
    |> Enum.uniq()
    |> Enum.sort_by(&wave_order/1)
    |> Enum.map(fn phase ->
      %{
        phase: phase,
        label: wave_label(phase),
        count: Map.get(counts, phase, 0),
        pct: Map.get(core_pct, phase),
        core?: Map.has_key?(core_pct, phase)
      }
    end)
  end

  # Complexity-weighted completion per wave, over CORE cards only. A merged card
  # contributes its full weight; an in-flight card contributes its progress
  # fraction; an unknown-progress card contributes nothing. Weight is the card's
  # complexity (points), defaulting to 1 when complexity is unknown.
  defp wave_completion(core_cards) do
    core_cards
    |> Enum.group_by(& &1.phase)
    |> Map.new(fn {phase, cards} ->
      {weight, done} =
        Enum.reduce(cards, {0, 0.0}, fn card, {w_acc, d_acc} ->
          weight = card.complexity || 1
          {w_acc + weight, d_acc + weight * completion_fraction(card)}
        end)

      pct = if weight > 0, do: round(done / weight * 100), else: 0
      {phase, pct}
    end)
  end

  defp completion_fraction(%{merged: true}), do: 1.0
  defp completion_fraction(%{has_progress: true, progress: progress}), do: progress / 100
  defp completion_fraction(_card), do: 0.0

  defp wave_order(:unphased), do: {1, 0}
  defp wave_order(phase) when is_integer(phase), do: {0, phase}

  defp wave_label(:unphased), do: "TBD"
  defp wave_label(phase) when is_integer(phase), do: "W#{phase}"

  # --- edges ------------------------------------------------------------------

  defp edges(%AiurWeb.BuildOrderViewModel{edges: edges}, core_cards) when is_list(edges) do
    id_by_key = Map.new(core_cards, &{&1.key, &1.id})

    edges
    |> Enum.flat_map(fn
      %Edge{source_key: source_key, target_key: target_key, state: state} ->
        with source when is_binary(source) <- Map.get(id_by_key, source_key),
             target when is_binary(target) <- Map.get(id_by_key, target_key) do
          [%{source: source, target: target, state: edge_state(state)}]
        else
          _missing -> []
        end

      _other ->
        []
    end)
  end

  defp edges(_model, _core_cards), do: []

  defp edge_state(:cleared), do: "cleared"
  defp edge_state("cleared"), do: "cleared"
  defp edge_state(_state), do: "blocking"

  # --- shared field helpers ---------------------------------------------------

  defp status_key(%Node{status_icon: %{key: key}}), do: key
  defp status_key(_node), do: nil

  defp core_state(:status_completed), do: :merged
  defp core_state(:status_working), do: :working
  defp core_state(:status_ready), do: :ready
  defp core_state(key) when key in [:status_blocking, :status_terminal_unsatisfied, :status_cyclic], do: :blocked
  defp core_state(_key), do: :plain

  defp core_status_word(:status_completed, _text), do: "merged"
  defp core_status_word(:status_working, _text), do: "agent live"
  defp core_status_word(:status_ready, _text), do: "dependency-ready"
  defp core_status_word(_key, text) when is_binary(text) and text != "", do: text
  defp core_status_word(_key, _text), do: "status unavailable"

  defp adhoc_status_word(:merged), do: "merged"
  defp adhoc_status_word(:working), do: "agent live"
  defp adhoc_status_word(_state), do: "ad hoc"

  defp progress(true, _raw), do: 100
  defp progress(false, raw) when is_integer(raw) and raw in 0..100, do: raw
  defp progress(false, _raw), do: 0

  defp complexity(%Node{plan: %{complexity: complexity}}) when complexity in 1..5, do: complexity
  defp complexity(_node), do: nil

  defp positive_complexity(complexity) when complexity in 1..5, do: complexity
  defp positive_complexity(_complexity), do: nil

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

  defp safe_title(title, _fallback) when is_binary(title) and title != "", do: title
  defp safe_title(_title, fallback), do: fallback
end
