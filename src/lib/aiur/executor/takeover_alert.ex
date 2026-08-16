defmodule Aiur.Executor.TakeoverAlert do
  @moduledoc """
  Pure core for configurable Executor takeover advisory alerts (#1182).

  The monitor (`Aiur.Executor.TakeoverAlert.Monitor`) drives a durable store
  and emits alerts through `Aiur.Alerts`; this module owns the clock- and
  config-pure decisions plus the actionable evidence message so they are
  unit-testable with an injected clock and no application boot.

  ## Convergence-age anchor rule

  A ticket's convergence age is `now − min(first_observed_active_work_at,
  open_pr_created_at)`:

  * `first_observed_active_work_at` is persisted durably per convergence
    episode in the daemon state store. It is set once the first time the
    monitor observes the ticket as nonterminal and in scope, and is never
    reset by a worker restart, redispatch, `max_turns` recycle, or daemon
    restart.
  * `open_pr_created_at` is the creation time of the ticket's open PR, when
    one exists. It acts as a floor so an already-open PR is never hidden by a
    freshly installed monitor or a restarted clock.

  A ticket that becomes terminal or leaves the configured run scope is
  forgotten (anchor + cadence state removed) and its active advisory is
  resolved; if it re-enters scope later, it starts a fresh convergence
  episode (the open-PR floor still applies to any surviving open PR).
  """

  @type thresholds :: %{
          first_hours: non_neg_integer(),
          continuous_hours: non_neg_integer()
        }

  @type decision :: :alert | :wait | :disabled

  @doc "Alert topic for a ticket's active takeover advisory."
  @spec topic(String.t()) :: String.t()
  def topic(identifier), do: "system.executor_takeover.#{identifier}"

  @doc "Resolution topic that clears a ticket's active takeover advisory in the alert feed."
  @spec resolution_topic(String.t()) :: String.t()
  def resolution_topic(identifier), do: topic(identifier) <> ".resolved"

  @doc "Whole hours elapsed between `anchor` and `now`, floored at zero."
  @spec age_hours(DateTime.t(), DateTime.t()) :: float()
  def age_hours(%DateTime{} = anchor, %DateTime{} = now) do
    max(DateTime.diff(now, anchor, :second), 0) / 3600
  end

  @doc """
  Durable convergence anchor: the earlier of the persisted first-observed
  active-work time and the open-PR creation floor. A `nil` PR time keeps the
  store anchor.
  """
  @spec effective_anchor(DateTime.t(), DateTime.t() | nil) :: DateTime.t()
  def effective_anchor(%DateTime{} = store_anchor, nil), do: store_anchor

  def effective_anchor(%DateTime{} = a, %DateTime{} = b) do
    case DateTime.compare(a, b) do
      :lt -> a
      _ -> b
    end
  end

  @doc """
  Whether a ticket should emit a takeover advisory right now.

    * `first_hours <= 0` → `:disabled` (no first alert, hence no repeats).
    * age below the first threshold → `:wait`.
    * no prior alert and age at/over the first threshold → `:alert` (first).
    * continuous disabled (`continuous_hours <= 0`) → `:wait` after the first.
    * otherwise → `:alert` only when at least `continuous_hours` elapsed since
      the last alert (repeated cadence), while age stays at/over the threshold.

  Negative or non-integer thresholds raise — the config changeset rejects them,
  but the monitor should never silently misbehave on a bad value.
  """
  @spec decide(thresholds(), float(), DateTime.t() | nil, DateTime.t()) :: decision()
  def decide(%{first_hours: f, continuous_hours: c}, age, last_alert, now) do
    f = require_non_negative(f, :executor_takeover_first_alert_hours)
    c = require_non_negative(c, :executor_takeover_continuous_alert_hours)

    cond do
      f <= 0 -> :disabled
      age < f -> :wait
      last_alert == nil -> :alert
      c <= 0 -> :wait
      age_hours(last_alert, now) >= c -> :alert
      true -> :wait
    end
  end

  @type evidence :: %{
          identifier: String.t(),
          title: String.t() | nil,
          url: String.t() | nil,
          age_hours: float(),
          anchor: DateTime.t(),
          now: DateTime.t(),
          first_hours: non_neg_integer(),
          continuous_hours: non_neg_integer(),
          repeated?: boolean(),
          live_owner?: boolean(),
          dispatches: non_neg_integer(),
          pr: map() | nil
        }

  @doc """
  Builds the actionable advisory message the Executor sees in
  `aiurdev alerts --needs-attention`. Every convergence-policy signal that is
  available is rendered; unknown evidence is explicitly marked so the Executor
  can distinguish "no PR / no owner" from "not yet observed".
  """
  @spec message(evidence()) :: String.t()
  def message(evidence) do
    label = "##{evidence.identifier}" <> title_suffix(evidence.title)
    age = Float.round(evidence.age_hours, 1)

    header =
      if evidence.repeated? do
        "Executor takeover advisory for #{label}: still converging after #{age}h " <>
          "(repeated reminder; cadence #{evidence.continuous_hours}h)."
      else
        "Executor takeover advisory for #{label}: converging for #{age}h " <>
          "(first alert; threshold #{evidence.first_hours}h)."
      end

    lines =
      [
        header,
        "  - Last material progress: " <> progress_line(evidence.pr, evidence.now),
        "  - Live owner: " <> owner_line(evidence.live_owner?),
        "  - Dispatch/restart count: " <> Integer.to_string(evidence.dispatches),
        "  - PR base/merge freshness: " <> mergeable_line(evidence.pr),
        "  - CI state: " <> ci_line(evidence.pr)
      ]

    Enum.join(lines, "\n")
  end

  defp require_non_negative(value, _name) when is_integer(value) and value >= 0, do: value

  defp require_non_negative(value, name) do
    raise ArgumentError, "#{name} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp title_suffix(nil), do: ""
  defp title_suffix(""), do: ""

  defp title_suffix(title) do
    case String.slice(title, 0, 80) do
      "" -> ""
      slice -> " (#{slice})"
    end
  end

  defp progress_line(nil, _now), do: "unavailable (no open PR observed)"

  defp progress_line(pr, now) when is_map(pr) do
    pushed = Map.get(pr, :pushed_at)
    number = Map.get(pr, :number)

    case pushed do
      %DateTime{} = pushed -> "PR ##{number} pushed #{human_age(pushed, now)} ago"
      _ -> "PR ##{number} (no push timestamp)"
    end
  end

  defp owner_line(true), do: "an agent is live on the ticket"
  defp owner_line(_false), do: "no live owning agent"

  defp mergeable_line(nil), do: "unavailable (no open PR observed)"

  defp mergeable_line(pr) when is_map(pr) do
    case Map.get(pr, :mergeable_state) do
      state when is_binary(state) and state != "" -> state
      _ -> "unknown"
    end
  end

  defp ci_line(nil), do: "unavailable (no open PR observed)"

  defp ci_line(pr) when is_map(pr) do
    case Map.get(pr, :ci_state) do
      state when is_binary(state) and state != "" -> state
      _ -> "unavailable"
    end
  end

  defp human_age(%DateTime{} = then, %DateTime{} = now) do
    minutes = max(div(DateTime.diff(now, then, :second), 60), 0)

    cond do
      minutes < 60 -> "#{minutes}m"
      minutes < 60 * 24 -> "#{Float.round(minutes / 60, 1)}h"
      true -> "#{Float.round(minutes / (60 * 24), 1)}d"
    end
  end
end
