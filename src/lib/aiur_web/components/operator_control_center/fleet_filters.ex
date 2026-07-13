defmodule AiurWeb.OperatorControlCenter.FleetFilters do
  @moduledoc false

  @filters [:running, :blocked, :paused, :stuck, :finished]
  @default_filters [:running, :blocked, :paused, :stuck]
  @blocked_reasons [:waiting_for_human, :waiting_for_supervisor, :waiting_for_dependency]
  @stuck_reasons [:backing_off, :unresponsive]
  @finished_states ["done", "closed", "cancelled", "canceled"]

  @spec default() :: MapSet.t()
  def default, do: MapSet.new(@default_filters)

  @spec all() :: [atom()]
  def all, do: @filters

  @spec toggle(MapSet.t(), String.t() | atom()) :: MapSet.t()
  def toggle(filters, filter) do
    case normalize(filter) do
      :all -> toggle_all(filters)
      normalized when normalized in @filters -> toggle_one(filters, normalized)
      _unknown -> filters
    end
  end

  @spec rows(map()) :: [map()]
  def rows(fleet) do
    running = Enum.map(Map.get(fleet, :running, []), &Map.put(&1, :bucket, :running))
    retrying = Enum.map(Map.get(fleet, :retrying, []), &Map.put(&1, :bucket, :retrying))
    idle = Enum.map(Map.get(fleet, :idle, []), &Map.put(&1, :bucket, :idle))
    running ++ retrying ++ idle
  end

  @spec visible_rows(map(), MapSet.t()) :: [map()]
  def visible_rows(fleet, filters) do
    Enum.filter(rows(fleet), &MapSet.member?(filters, state(&1)))
  end

  @spec counts(map()) :: map()
  def counts(fleet) do
    rows = rows(fleet)

    @filters
    |> Map.new(&{&1, Enum.count(rows, fn row -> state(row) == &1 end)})
    |> Map.put(:all, length(rows))
  end

  @spec state(map()) :: atom()
  def state(row) do
    cond do
      finished?(row) -> :finished
      paused?(row) -> :paused
      row[:waiting_reason] in @stuck_reasons -> :stuck
      row[:waiting_reason] in @blocked_reasons or open_decision?(row) -> :blocked
      true -> :running
    end
  end

  defp normalize(filter) when is_atom(filter), do: filter

  defp normalize(filter) when is_binary(filter) do
    Enum.find([:all | @filters], &(Atom.to_string(&1) == filter))
  end

  defp normalize(_filter), do: nil

  defp toggle_all(filters) do
    all = MapSet.new(@filters)
    if MapSet.equal?(filters, all), do: MapSet.new(), else: all
  end

  defp toggle_one(filters, filter) do
    if MapSet.member?(filters, filter), do: MapSet.delete(filters, filter), else: MapSet.put(filters, filter)
  end

  defp paused?(row),
    do: row[:tracker_paused] == true or row[:work_state] in [:paused, "paused"] or row[:waiting_reason] == :paused

  defp open_decision?(%{open_decision_count: count}) when is_integer(count), do: count > 0
  defp open_decision?(_row), do: false

  defp finished?(row) do
    normalized = row[:state] |> to_string() |> String.downcase()
    normalized in @finished_states
  end
end
