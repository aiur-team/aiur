defmodule AiurWeb.BuildQueue.Copy do
  @moduledoc "Provisional DESIGN-E1 dashboard copy, kept together for owner review."

  @strings %{
    title: "Build queue",
    intro: "Read-only. Manage queues with the CLI.",
    loading: "Loading build queues…",
    empty: "No build queues yet. Start one with aiur queue add <ids…>.",
    disabled: "Build queue is disabled.",
    unsupported_tracker: "This tracker does not support build queues.",
    store_unavailable: "Queue store unavailable; promotion paused.",
    writes_paused: "Queue writes paused by the GitHub budget. Held data remains visible.",
    stale: "Queue data is stale. Readiness is shown from held evidence.",
    unknown: "Queue readiness unknown. Wait for current evidence; do not promote by hand.",
    observed: "Observed",
    age: "Age",
    freshness: "Freshness",
    current: "Current",
    unavailable: "Unavailable",
    unknown_value: "Unknown",
    position: "Position",
    ticket: "Ticket",
    state: "State",
    waiting_on: "Waiting on",
    rank: "Start-order rank",
    attentions: "Attentions",
    no_prerequisites: "No waiting prerequisites",
    no_attentions: "No open attentions",
    held_queue: "Queue held",
    waiting: "Waiting",
    pending: "Waiting for completion",
    ready: "Ready for promotion",
    promoted: "Promoted",
    promoted_unauthorized: "Promoted (unauthorized)",
    claimed: "Claimed",
    held: "Held",
    overridden: "Overridden",
    failed_prerequisite: "Failed prerequisite",
    completed: "Completed",
    cancelled: "Cancelled",
    removed: "Removed",
    satisfied: "Satisfied",
    failed: "Failed",
    unresolved: "Unresolved",
    partial: "Partial",
    resolved: "Resolved",
    resolved_notice: "Resolved attentions remain visible for 60 seconds.",
    none: "—"
  }

  @spec strings() :: map()
  def strings, do: @strings

  @spec text(atom()) :: String.t()
  def text(key), do: Map.get(@strings, key, @strings.unknown_value)

  @spec label(atom()) :: String.t()
  def label(:unknown), do: text(:unknown_value)
  def label(key), do: text(key)

  @spec timestamp(term()) :: String.t()
  def timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def timestamp(_value), do: text(:unknown_value)

  @spec age(integer() | nil) :: String.t()
  def age(ms) when is_integer(ms), do: "#{div(ms, 1000)}s ago"
  def age(_value), do: text(:unknown_value)

  @spec rank(map()) :: String.t()
  def rank(%{downstream_open: count, rank: {_, priority, _, _, _}}) when is_integer(count), do: "#{count} open downstream · priority #{priority}"
  def rank(_item), do: text(:unknown_value)

  @spec reason(term()) :: String.t()
  def reason(nil), do: text(:none)
  def reason(value), do: value |> inspect() |> String.replace("_", " ")

  @spec prerequisite(map()) :: String.t()
  def prerequisite(edge), do: "##{edge.number} · #{label(edge.verdict)} · #{reason(edge.source)}"

  @spec progress(map()) :: String.t()
  def progress(%{resolution: resolution} = progress) when resolution in [:resolved, :partial] and is_number(progress.percent) do
    "#{progress.percent}% · #{progress.completed}/#{progress.total} completed · #{text(resolution)} (#{progress.resolved}/#{progress.total})"
  end

  def progress(progress), do: label(progress.resolution)
end
