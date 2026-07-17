defmodule Aiur.CurrentRunSummary.Facts do
  @moduledoc false

  alias Aiur.CurrentRunProjection.Value
  alias AiurWeb.OperatorControlCenter.UnitsPolicy

  @nonterminal_lifecycles [:queued, :retrying, :allocated, :running, :paused, :waiting, :replaced]
  @cancelled_states ~w(cancelled canceled not_planned notplanned)

  @spec rows(map()) :: [map()]
  def rows(units) do
    units
    |> Value.get(:rows, [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  @spec run(map()) :: map()
  def run(run) when is_map(run) do
    id = Value.get(run, :id)
    started_at = Value.get(run, :started_at)
    observed_at = Value.get(run, :observed_at)
    elapsed_ms = Value.get(run, :elapsed_ms)

    %{
      id: id,
      started_at: started_at,
      observed_at: observed_at,
      elapsed_wall_ms: valid_elapsed(elapsed_ms),
      elapsed_wall_seconds: elapsed_seconds(elapsed_ms),
      valid?: Value.get(run, :valid?, true) == true and valid_run?(id, started_at, observed_at, elapsed_ms)
    }
  end

  def run(_run) do
    %{id: nil, started_at: nil, observed_at: nil, elapsed_wall_ms: nil, elapsed_wall_seconds: nil, valid?: false}
  end

  @spec members([map()]) :: [map()]
  def members(rows), do: Enum.map(rows, &member/1)

  @spec counts([map()], [map()]) :: map()
  def counts(rows, members) do
    %{
      live: Enum.count(rows, &UnitsPolicy.in_scope?(&1, :live)),
      remaining: Enum.count(rows, &UnitsPolicy.in_scope?(&1, :unfinished)),
      successful_terminal: Enum.count(members, &(&1.class == :successful_terminal)),
      non_work_terminal: Enum.count(members, &(&1.class == :non_work_terminal)),
      unknown_state: Enum.count(members, &(&1.class == :unknown)),
      total: length(rows)
    }
  end

  @spec weights([map()]) :: map()
  def weights(members) do
    eligible = Enum.reject(members, &(&1.class == :non_work_terminal))
    successful = Enum.filter(eligible, &(&1.class == :successful_terminal))
    excluded = Enum.filter(members, &(&1.class == :non_work_terminal))
    defaulted = Enum.filter(members, & &1.defaulted?)
    known = Enum.filter(eligible, &match?({:known, _percent}, &1.progress))
    unknown = eligible -- known
    eligible_weight = sum(eligible)
    successful_weight = sum(successful)

    %{
      eligible: eligible_weight,
      successful_terminal: successful_weight,
      remaining: eligible_weight - successful_weight,
      excluded: sum(excluded),
      excluded_count: length(excluded),
      defaulted: sum(defaulted),
      defaulted_count: length(defaulted),
      known_progress: sum(known),
      unknown_progress: sum(unknown)
    }
  end

  @spec denominator_signature([map()]) :: String.t()
  def denominator_signature(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn row ->
      fact = member(row)
      {identity_key(row), fact.weight, fact.class == :non_work_terminal}
    end)
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def denominator_signature(_rows), do: denominator_signature([])

  defp member(row) do
    {weight, defaulted?} = complexity_weight(Map.get(row, :complexity))
    class = state_class(row)
    %{row: row, class: class, weight: weight, defaulted?: defaulted?, progress: member_progress(row, class)}
  end

  defp complexity_weight(value) when is_integer(value) and value in 1..5, do: {value, false}
  defp complexity_weight(_value), do: {1, true}

  defp state_class(row) do
    cond do
      non_work_terminal?(row) -> :non_work_terminal
      row[:terminal?] == true and row[:lifecycle] == :completed -> :successful_terminal
      row[:terminal?] != true and row[:lifecycle] in @nonterminal_lifecycles -> :nonterminal
      true -> :unknown
    end
  end

  defp non_work_terminal?(row) do
    row[:terminal?] == true and
      (row[:lifecycle] == :cancelled or normalize_state(row[:tracker_state]) in @cancelled_states)
  end

  defp normalize_state(state) when is_atom(state), do: state |> Atom.to_string() |> normalize_state()

  defp normalize_state(state) when is_binary(state) do
    state |> String.trim() |> String.downcase() |> String.replace(~r/[\s-]+/, "_") |> String.replace("_", "")
  end

  defp normalize_state(_state), do: ""
  defp member_progress(_row, :non_work_terminal), do: :excluded
  defp member_progress(_row, :successful_terminal), do: {:known, 100}
  defp member_progress(_row, :unknown), do: {:unknown, :contradictory_state}

  defp member_progress(row, :nonterminal) do
    progress = Map.get(row, :progress)

    cond do
      known_not_started?(row) and unknown_progress?(progress) -> {:known, 0}
      known_not_started?(row) and fresh_percent(progress) == 0 -> {:known, 0}
      known_not_started?(row) -> {:unknown, :contradictory_queued_progress}
      is_integer(fresh_percent(progress)) -> {:known, clamp(fresh_percent(progress), 0, 100)}
      stale_progress?(progress) -> {:unknown, :stale}
      true -> {:unknown, :missing_or_malformed}
    end
  end

  defp known_not_started?(row) do
    row[:terminal?] != true and (row[:lifecycle] == :queued or row[:replacement_boundary?] == true) and
      UnitsPolicy.condition?(:queued, row)
  end

  defp unknown_progress?(nil), do: true
  defp unknown_progress?(%{status: :unknown}), do: true
  defp unknown_progress?(_progress), do: false
  defp fresh_percent(%{status: :known, freshness: :fresh, percent: percent}) when is_integer(percent), do: percent
  defp fresh_percent(_progress), do: nil
  defp stale_progress?(%{freshness: :stale}), do: true
  defp stale_progress?(_progress), do: false
  defp sum(members), do: Enum.reduce(members, 0, &(&2 + &1.weight))
  defp valid_elapsed(value) when is_integer(value) and value >= 0, do: value
  defp valid_elapsed(_value), do: nil
  defp elapsed_seconds(value) when is_integer(value) and value >= 0, do: div(value, 1_000)
  defp elapsed_seconds(_value), do: nil

  defp valid_run?(id, %DateTime{} = started_at, %DateTime{} = observed_at, elapsed_ms) do
    is_binary(id) and String.trim(id) != "" and DateTime.compare(observed_at, started_at) != :lt and
      is_integer(elapsed_ms) and elapsed_ms >= 0
  end

  defp valid_run?(_id, _started_at, _observed_at, _elapsed_ms), do: false
  defp identity_key(row), do: Aiur.TrackerIdentity.github_key(Map.get(row, :identity)) || {:unjoinable, nil}
  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value
end
