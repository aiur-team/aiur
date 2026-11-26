defmodule Aiur.Intent.Reconciler do
  @moduledoc """
  Pure fold of shared-intent changes into registers (plan "Reconciliation", MPG-403 amendments A1-A3).

  The result depends only on the set of changes: arrival order and duplicates do not matter. No I/O,
  no clock; `now_ms` and `own_gateway` are explicit inputs.
  """

  alias Aiur.Intent.Change

  @skew_ms 60_000
  @slots [:human, :executor, :default]
  @empty %{human: nil, executor: nil, default: nil, honored: nil}

  @type register_key :: {String.t(), String.t(), String.t()}

  @doc """
  Folds `changes` into `%{{kind, key, field} => %{effective:, winning_change_id:, slot:, takeover:, slots:}}`.

  Options: `now_ms` (changes more than 60 s ahead of it are held; absent means nothing is held) and
  `own_gateway` (its changes are never held).
  """
  @spec fold([Change.t()], keyword()) :: %{register_key() => map()}
  def fold(changes, opts \\ []) do
    now = opts[:now_ms]
    own = opts[:own_gateway]

    changes
    |> Enum.uniq_by(& &1.change_id)
    |> Enum.reject(&(invalid?(&1) or held?(&1, now, own)))
    |> Enum.sort_by(&sort_key/1)
    |> Enum.reduce(%{}, fn c, acc -> Map.update(acc, register(c), step(@empty, c), &step(&1, c)) end)
    |> Map.new(fn {reg, state} -> {reg, summarize(reg, state)} end)
  end

  @doc "The changes `fold/2` would hold; shares its predicate."
  @spec held([Change.t()], integer(), String.t() | nil) :: [Change.t()]
  def held(changes, now_ms, own_gateway) do
    changes |> Enum.uniq_by(& &1.change_id) |> Enum.filter(&held?(&1, now_ms, own_gateway))
  end

  @doc "True iff the change is strictly more than 60 s ahead of `now_ms` and not locally authored."
  @spec held?(Change.t(), integer() | nil, String.t() | nil) :: boolean()
  def held?(_change, nil, _own), do: false
  def held?(%Change{origin_gateway: own}, _now, own) when not is_nil(own), do: false
  def held?(%Change{hlc_wall_ms: wall}, now, _own), do: wall > now + @skew_ms

  # A2: a daemon never writes pause; a row from a buggy peer is ignored.
  defp invalid?(%Change{slot: "default", field: "pause"}), do: true
  defp invalid?(_), do: false

  # A1: a pause sorts last in an exact HLC tie.
  defp sort_key(c), do: {c.hlc_wall_ms, c.hlc_counter, pause_rank(c), c.origin_gateway, c.change_id}
  defp pause_rank(%Change{field: "pause", value_json: true}), do: 1
  defp pause_rank(_), do: 0

  defp register(c), do: {c.entity_kind, c.entity_key, c.field}

  # Rule 5: a human unpause clears every slot.
  defp step(_state, %Change{slot: "human", field: "pause", value_json: false} = c), do: %{@empty | human: c}

  # Rule 3: a forced takeover clears the human slot only if it names the change current at this point of the fold.
  defp step(%{human: %Change{change_id: id}} = state, %Change{slot: "executor", force: true, supersedes: id} = c) do
    if blank?(c.reason), do: put(state, c), else: put(%{state | human: nil}, c, c.change_id)
  end

  defp step(state, c), do: put(state, c)

  defp put(state, c, honored \\ nil) do
    slot = String.to_existing_atom(c.slot)
    state = Map.put(state, slot, c)
    if slot == :executor, do: %{state | honored: honored}, else: state
  end

  defp blank?(reason), do: not is_binary(reason) or String.trim(reason) == ""

  defp summarize({_, _, "pause"}, state) do
    set = state |> slots() |> Enum.filter(fn {_, c} -> c && c.value_json == true end)

    case set do
      [] -> finish(state, false, first_slot(state))
      _ -> finish(state, true, set |> Enum.max_by(fn {_, c} -> sort_key(c) end) |> elem(0))
    end
  end

  defp summarize(_reg, state) do
    slot = first_slot(state)
    finish(state, Map.fetch!(state, slot).value_json, slot)
  end

  defp finish(state, effective, slot) do
    win = Map.fetch!(state, slot)
    takeover = if slot == :executor and state.honored == win.change_id, do: win.change_id

    %{effective: effective, winning_change_id: win.change_id, slot: slot, takeover: takeover, slots: Map.take(state, @slots)}
  end

  defp first_slot(state), do: Enum.find(@slots, &Map.fetch!(state, &1))
  defp slots(state), do: Map.take(state, @slots)
end
