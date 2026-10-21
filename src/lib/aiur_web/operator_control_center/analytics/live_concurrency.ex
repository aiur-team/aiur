defmodule AiurWeb.OperatorControlCenter.Analytics.LiveConcurrency do
  @moduledoc false

  @spec snapshot_opts(term()) :: keyword()
  def snapshot_opts({:current, %{running: running} = snapshot, _freshness}) when is_list(running),
    do: [live_concurrency: count(running), live_occupied: occupied(snapshot), live_concurrency_state: :current]

  def snapshot_opts({:stale, %{running: running} = snapshot, freshness}) when is_list(running),
    do: [live_concurrency: count(running), live_occupied: occupied(snapshot), live_concurrency_state: {:stale, age_ms(freshness)}]

  def snapshot_opts({:current, _snapshot, _freshness}), do: [live_concurrency_state: :running_unavailable]
  def snapshot_opts({:stale, _snapshot, freshness}), do: [live_concurrency_state: {:stale_unavailable, age_ms(freshness)}]
  def snapshot_opts(:snapshot_unpublished), do: [live_concurrency_state: :snapshot_unpublished]
  def snapshot_opts(:orchestrator_unavailable), do: [live_concurrency_state: :orchestrator_unavailable]
  def snapshot_opts(_other), do: [live_concurrency_state: :snapshot_unavailable]

  @spec count([map()]) :: non_neg_integer()
  def count(running) do
    Enum.count(running, fn
      %{work_state: state} when state in [:paused, :error, :completed, :deactivated] -> false
      %{work_state: state} when state in ["paused", "error", "completed", "deactivated"] -> false
      _row -> true
    end)
  end

  defp occupied(%{capacity: %{occupied: count}}) when is_integer(count) and count >= 0, do: count
  defp occupied(_snapshot), do: nil

  @doc false
  @spec label(map(), boolean()) :: String.t()
  @spec label(map(), boolean(), map()) :: String.t()
  def label(model, present?, %{kind: :build_order}),
    do: "#{known_or_unknown(model.kpis.conc_now)} #{if(present?, do: "now", else: "at run end")}"

  def label(model, present?, scope), do: label(model, present? and scope == :session)

  @spec label(map(), boolean()) :: String.t()
  def label(model, true) do
    case Map.get(model, :live_concurrency) do
      count when is_integer(count) -> "#{count} running now#{occupied_label(Map.get(model, :live_occupied), count)}#{freshness_label(Map.get(model, :live_concurrency_state))}"
      _unknown -> "occupancy unavailable#{freshness_label(Map.get(model, :live_concurrency_state))}"
    end
  end

  def label(model, false), do: "#{known_or_unknown(model.kpis.conc_now)} at run end"

  defp known_or_unknown(nil), do: "unknown"
  defp known_or_unknown(count), do: to_string(count)

  defp occupied_label(occupied, count) when is_integer(occupied) and occupied != count, do: " (#{occupied} slots occupied)"
  defp occupied_label(_occupied, _count), do: ""

  defp freshness_label({:stale, nil}), do: " (sample age unknown)"
  defp freshness_label({:stale_unavailable, nil}), do: " (sample age unknown)"
  defp freshness_label({:stale, age_ms}), do: " (sample #{age_label(age_ms)} old)"
  defp freshness_label({:stale_unavailable, age_ms}), do: " (sample #{age_label(age_ms)} old)"
  defp freshness_label(_freshness), do: ""

  defp age_label(nil), do: "age unknown"
  defp age_label(age_ms) when age_ms <= 30_000, do: "just now"
  defp age_label(age_ms) when age_ms < 60_000, do: "#{div(age_ms, 1_000)}s"
  defp age_label(age_ms) when age_ms < 3_600_000, do: "#{div(age_ms, 60_000)}m"
  defp age_label(age_ms), do: "#{Float.round(age_ms / 3_600_000, 1)}h"

  defp age_ms(%{age_ms: age_ms}) when is_integer(age_ms) and age_ms >= 0, do: age_ms
  defp age_ms(_freshness), do: nil
end
