defmodule Aiur.Orchestrator.StatusReport.Progress do
  @moduledoc false
  # Joins live and retained ticket activity into per-identity progress facts.

  alias Aiur.ProgressRetention
  alias Aiur.TicketActivity
  alias Aiur.TrackerIdentity

  # `TicketActivity.snapshots/1` is a call into an in-memory projection on this
  # node, so the work itself is microseconds; the only thing this budget has to
  # cover is queueing. 100 ms did not: behind a burst of ticket events, or any
  # ordinary VM pause, the call timed out and the whole fleet's progress
  # collapsed to a single failure value at once.
  #
  # 500 ms is bounded from both sides. Below, it is five times the budget that
  # was observed to fail, which puts it far outside normal mailbox queueing for
  # a projection this small. Above, this call blocks the Orchestrator process
  # while it runs and snapshots are rebuilt on every state change, so it must
  # stay comfortably inside the smallest caller budget in the tree (1 s, e.g.
  # `Orchestrator.snapshot/2`) and leave room for the rest of the payload. Half
  # of that is the largest value that still does.
  @activity_snapshot_timeout_ms 500

  # An unreachable, unstarted or too-slow TicketActivity yields an empty join,
  # which `progress_facts/2` reads as `:unknown` for every identity it looks
  # up. That distinction is the whole point: the failure path must say "we
  # could not measure", never "every agent is at 0%", which is what the fleet
  # used to report in unison on any transient hiccup here.
  #
  # Retained readings from `ProgressRetention` backfill every identity the live
  # projection cannot see — a `TicketActivity.snapshots/1` timeout, a projection
  # that has not finished seeding after a restart, or a `:recent` entry pruned
  # after its in-memory retention window. Live projection entries always win
  # when they carry a `:known` reading; a live entry whose progress is
  # `:unknown` (nil — e.g. a `:recent` entry recreated by a stage-only event
  # after the progress entry was pruned) must not blank a retained value. A
  # ticket that never reported has neither, so `:unknown` survives as
  # "never reported" (#1963).
  @doc false
  @spec activity_by_identity() :: map()
  def activity_by_identity do
    retained = retained_activity_by_identity()
    live = live_activity_by_identity()

    Map.merge(retained, live, fn _key, retained_entry, live_entry ->
      if live_progress_known?(live_entry), do: live_entry, else: retained_entry
    end)
  end

  defp live_progress_known?(%{progress: %{status: :known}}), do: true
  defp live_progress_known?(_entry), do: false

  defp live_activity_by_identity do
    with pid when is_pid(pid) <- Process.whereis(TicketActivity),
         %{entries: entries} when is_list(entries) <-
           TicketActivity.snapshots(timeout: @activity_snapshot_timeout_ms) do
      Enum.reduce(entries, %{}, &put_activity_entry/2)
    else
      _ -> %{}
    end
  catch
    :exit, _ -> %{}
  end

  defp retained_activity_by_identity do
    case ProgressRetention.all() do
      retained when is_map(retained) and retained != %{} ->
        Map.new(retained, fn {key, %{progress: progress}} ->
          {key, retained_activity_entry(progress)}
        end)

      _ ->
        %{}
    end
  end

  # The retained fallback reports the real last-known percent as `:stale`: by
  # the time the live projection cannot serve a reading, it is at least as old
  # as the projection's staleness window would have marked it, and staleness is
  # the operator-accepted grey for "real value, a while ago". `:unknown` stays
  # reserved for never-reported. This deliberately does not substitute `0` —
  # the value shown is the measurement, never a placeholder.
  defp retained_activity_entry(%{percent: percent}) do
    %{progress: %{status: :known, freshness: :stale, percent: normalized_percent(percent)}}
  end

  defp retained_activity_entry(_progress), do: %{progress: %{status: :unknown, freshness: :unknown, percent: nil}}

  defp put_activity_entry(entry, acc) do
    case TrackerIdentity.github_key(Map.get(entry, :identity)) do
      nil -> acc
      identity_key -> Map.put(acc, identity_key, entry)
    end
  end

  # Progress has three honest states, and every consumer gets all three:
  #
  #   :fresh   - observed inside the TicketActivity staleness window.
  #   :stale   - a real reading exists but is older than the window. The
  #              percent is RETAINED. `Projection.progress_snapshot/3` keeps
  #              the measured value on purpose and only annotates its age; the
  #              honest reading of an aged 70% is "70%, a while ago", never 0%.
  #   :unknown - nothing was ever observed for this ticket, or TicketActivity
  #              could not be consulted at all. The percent is `nil`.
  #
  # This used to substitute integer `0` for both of the latter two, which made
  # the Stream Deck flicker 0 -> 70 -> 0 on a ticket that was progressing
  # perfectly well: agents do not re-emit progress every minute, so a good
  # reading went stale about a minute after it landed and was replaced by a
  # measurement nobody took.
  @doc false
  @spec progress_facts(term(), map()) :: %{progress_percent: 0..100 | nil, progress_freshness: :fresh | :stale | :unknown}
  def progress_facts(identity, activity_by_identity) do
    case get_in(activity_by_identity, [TrackerIdentity.github_key(identity), :progress]) do
      %{status: :known, freshness: freshness, percent: percent}
      when freshness in [:fresh, :stale] ->
        known_progress_facts(freshness, normalized_percent(percent))

      _ ->
        %{progress_percent: nil, progress_freshness: :unknown}
    end
  end

  defp known_progress_facts(_freshness, nil), do: %{progress_percent: nil, progress_freshness: :unknown}

  defp known_progress_facts(freshness, percent), do: %{progress_percent: percent, progress_freshness: freshness}

  # Agents emit whole percentages today, but a float is a real measurement and
  # rounding keeps it. The previous `is_integer/1` guard silently turned 70.5
  # into 0 — the one thing a percent must never be turned into.
  defp normalized_percent(percent) when is_integer(percent) and percent in 0..100, do: percent
  defp normalized_percent(percent) when is_float(percent), do: percent |> round() |> normalized_percent()
  defp normalized_percent(_percent), do: nil

  # Sibling of `progress_facts/2` over the same joined TicketActivity entry:
  # the agent's workflow stage (brainstorm/plan/work/review).
  #
  # Deliberately NOT annotated with freshness, where progress is. The two look
  # alike and are not. Progress is a measurement that decays: an hour-old 40%
  # may no longer be true, so its age travels with it. A stage is a *state* with
  # explicit transitions — it changes only when the agent emits
  # `phase.<stage>.start|end`, and `observed_at` records that transition, not a
  # confirmation that the state still holds. Requiring it to be recent asks the
  # agent to keep re-announcing a phase it never left: with the default
  # 60-second staleness window, a twenty-minute work phase would report its
  # stage for the first minute and nothing for the other nineteen. The reducer
  # already writes `value: nil` on a phase end, so a finished phase clears
  # itself rather than lingering.
  @doc false
  @spec activity_stage(term(), map()) :: atom() | nil
  def activity_stage(identity, activity_by_identity) do
    case get_in(activity_by_identity, [TrackerIdentity.github_key(identity), :stage]) do
      %{status: :known, value: stage} when is_atom(stage) and not is_nil(stage) -> stage
      _ -> nil
    end
  end
end
