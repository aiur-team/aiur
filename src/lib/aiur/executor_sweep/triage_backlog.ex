defmodule Aiur.ExecutorSweep.TriageBacklog do
  @moduledoc """
  Open `needs-triage` tickets older than an hour. Nothing dispatches them, so
  `aiur status` prints the count and the sweep wakes the Executor per newly
  stale ticket (#4521). Both read the open-ticket projection, so closed
  tickets that still carry the label never count.
  """

  alias Aiur.OpenTicketSource.Snapshot

  @stale_ms 60 * 60_000

  @doc "Whether a ticket with these labels, created at `created_at`, has needed triage for over an hour."
  @spec stale?([String.t()], DateTime.t() | nil, DateTime.t()) :: boolean()
  def stale?(labels, %DateTime{} = created_at, %DateTime{} = now), do: "needs-triage" in labels and DateTime.diff(now, created_at, :millisecond) > @stale_ms
  def stale?(_labels, _created_at, _now), do: false

  @doc "Stale `needs-triage` tickets, oldest first; empty unless the projection is `:available`."
  @spec stale_tickets(Snapshot.t() | nil, DateTime.t()) :: [Snapshot.ticket()]
  def stale_tickets(%Snapshot{status: :available, tickets: tickets}, %DateTime{} = now), do: stale(tickets, now)
  def stale_tickets(_snapshot, _now), do: []

  @doc "`TRIAGE needs-triage >1h N (oldest #id <age>)` from the open-ticket projection."
  @spec status_line(Snapshot.t(), DateTime.t()) :: String.t()
  def status_line(%Snapshot{status: :unsupported}, _now), do: "TRIAGE unsupported (tracker has no open-ticket listing)"
  def status_line(%Snapshot{status: :unavailable}, _now), do: "TRIAGE unavailable (the open-ticket listing is not loaded)"

  def status_line(%Snapshot{} = snapshot, %DateTime{} = now) do
    stale = stale(snapshot.tickets, now)
    unknown = Enum.count(snapshot.tickets, &("needs-triage" in &1.labels and is_nil(&1.created_at)))
    count = if snapshot.truncated?, do: ">=#{length(stale)}", else: "#{length(stale)}"

    oldest =
      case stale do
        [] -> ""
        [oldest | _] -> " (oldest ##{oldest.identifier} #{age(DateTime.diff(now, oldest.created_at))})"
      end

    "TRIAGE needs-triage >1h " <>
      count <>
      oldest <>
      if(unknown > 0, do: " unknown age #{unknown}", else: "") <>
      if(snapshot.truncated?, do: " TRUNCATED", else: "") <>
      if(snapshot.status == :stale, do: " STALE #{observed(snapshot.observed_at, now)}", else: "")
  end

  @doc "Prints the status line from the live open-ticket projection."
  @spec print_status(GenServer.server()) :: :ok
  def print_status(server \\ Aiur.OpenTicketSource), do: IO.puts(status_line(Aiur.OpenTicketSource.snapshot(server), DateTime.utc_now()))

  defp stale(tickets, now), do: tickets |> Enum.filter(&stale?(&1.labels, &1.created_at, now)) |> Enum.sort_by(& &1.created_at, DateTime)

  defp observed(%DateTime{} = at, now), do: "observed #{age(DateTime.diff(now, at))} ago"
  defp observed(nil, _now), do: "observed age unknown"

  defp age(seconds) when seconds < 3600, do: "#{div(max(seconds, 0), 60)}m"
  defp age(seconds), do: "#{div(seconds, 3600)}h"
end
