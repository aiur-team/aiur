defmodule AiurWeb.Build.Index.RefreshState do
  @moduledoc false

  alias Aiur.BuildOrder.Index, as: Core

  @settings_startup_timeout_ms 600_000

  @spec retry_after_finish(map(), term(), boolean(), map()) :: {non_neg_integer(), MapSet.t()}
  def retry_after_finish(state, next, now_failed?, parts) do
    settings_loading? = match?({:error, :settings_loading}, next)
    failures = if now_failed? or settings_loading?, do: state.failures + 1, else: state.failures
    retry_dirty = if now_failed?, do: MapSet.put(state.dirty, :now), else: state.dirty
    retry_dirty = if settings_loading?, do: MapSet.put(retry_dirty, :settings), else: retry_dirty

    retry_dirty =
      if match?({:error, :settings_startup_timeout}, parts[:settings]),
        do: MapSet.delete(retry_dirty, :settings),
        else: retry_dirty

    {failures, retry_dirty}
  end

  @spec expire_settings_loading(map(), map(), term(), integer()) :: {map(), term(), integer() | nil}
  def expire_settings_loading(state, parts, {:error, :settings_loading} = next, now) do
    started_at = state.settings_loading_since_ms || now
    timeout = Keyword.get(state.opts, :settings_startup_timeout_ms, @settings_startup_timeout_ms)

    if now - started_at >= timeout do
      parts = Map.put(parts, :settings, {:error, :settings_startup_timeout})
      {parts, Core.assemble(parts, now: now), nil}
    else
      {parts, next, started_at}
    end
  end

  def expire_settings_loading(_state, parts, next, _now), do: {parts, next, nil}

  @spec changes(term(), term()) :: map() | nil
  def changes({:ok, old}, {:ok, new}) do
    if old.hist == [] and new.hist != [] and
         old.sources.history.state in ["unavailable", "incomplete"] do
      %{resync: true}
    else
      ordinary_changes(old, new)
    end
  end

  def changes(_, _), do: %{resync: true}

  defp ordinary_changes(old, new) do
    case Core.diff(old, new) do
      %{upsert: [], remove: [], set: set} when map_size(set) == 0 -> nil
      diff -> Map.put(diff, :resync, false)
    end
  end

  @spec record_read_staleness(map(), MapSet.t(), term()) :: map()
  def record_read_staleness(parts, dirty, reason) do
    stale = Map.get(parts, :read_stale, %{})
    stale = Enum.reduce(dirty, stale, &Map.put(&2, &1, reason))
    Map.put(parts, :read_stale, stale)
  end

  @spec clear_read_staleness(map(), MapSet.t()) :: map()
  def clear_read_staleness(parts, dirty) do
    stale = Map.get(parts, :read_stale, %{}) |> Map.drop(MapSet.to_list(dirty))
    Map.put(parts, :read_stale, stale)
  end

  @spec mark_failed_part(map(), atom(), term()) :: map()
  def mark_failed_part(parts, :history, reason), do: Map.put(parts, :history, {:error, reason}) |> Map.put(:health, {:error, reason})
  def mark_failed_part(parts, :health, reason), do: Map.put(parts, :health, {:error, reason})
  def mark_failed_part(parts, :features, reason), do: Map.put(parts, :features, {:error, reason})
  def mark_failed_part(parts, :now, reason), do: Map.put(parts, :now, {:error, reason})
  def mark_failed_part(parts, :packs, _reason), do: Map.put(parts, :packs, {:error, :read_failed})
  def mark_failed_part(parts, :queue, reason), do: Map.put(parts, :planned, {:error, reason})
  def mark_failed_part(parts, :planned, reason), do: Map.put(parts, :planned, {:error, reason})

  def mark_failed_part(parts, :open, reason),
    do: parts |> Map.put(:open, {:error, reason}) |> mark_open_degraded(reason)

  def mark_failed_part(parts, :not_queued, reason), do: Map.put(parts, :not_queued, {:error, reason})
  def mark_failed_part(parts, _part, _reason), do: parts

  @spec retain_failed_agents(map(), map(), term(), atom()) :: map()
  def retain_failed_agents(parts, previous, part, failure) when part in [:now, nil, :unknown] do
    case previous[:now] do
      %{rows: rows, source: %{state: state} = source}
      when is_map(rows) and state in ["ok", "stale"] ->
        Map.put(parts, :now, %{
          rows: rows,
          source: %{source | state: "stale", reason: Atom.to_string(failure)}
        })

      _ ->
        parts
    end
  end

  def retain_failed_agents(parts, _previous, _part, _failure), do: parts

  defp mark_open_degraded(parts, failure) do
    reasons = [if(failure == :timeout, do: :open_tickets_timeout, else: :open_tickets_read_failed)]

    case parts[:not_queued] do
      %{state: _state, reasons: _reasons} = not_queued ->
        Map.put(parts, :not_queued, %{not_queued | state: :unavailable, reasons: reasons})

      _other ->
        Map.put(parts, :not_queued, %{
          state: :unavailable,
          reasons: reasons,
          observed_at: nil,
          truncated?: false,
          skipped: 0,
          rows: []
        })
    end
  end
end
