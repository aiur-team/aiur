defmodule Aiur.ExecutorBindings do
  @moduledoc false

  alias Aiur.ExecutorEvents

  @defaults [
    {"executor.#", "commands:auto"},
    {"system.dispatch.capacity_starved", "dispatch:auto"},
    {"system.dispatch.capacity_starved.resolved", "dispatch:auto"},
    {"system.fleet.capacity.starved", "dispatch:auto"},
    {"system.fleet.capacity.starved.resolved", "dispatch:auto"},
    {"system.dispatch.prewarm_blocked", "dispatch:auto"},
    {"system.dispatch.prewarm_blocked.resolved", "dispatch:auto"},
    {"system.dispatch.todo_capacity_exceeded", "dispatch:auto"},
    {"system.tracker.auth_preflight_failed", "dispatch:auto"},
    {"system.tracker.auth_preflight_failed.resolved", "dispatch:auto"},
    {"system.fleet.capacity.backoff", "dispatch:auto"},
    {"system.fleet.capacity.resumed", "dispatch:auto"},
    {"system.fleet.contradictory_state_labels", "dispatch:auto"},
    {"system.fleet.contradictory_state_labels.resolved", "dispatch:auto"},
    {"system.github.connectivity_lost", "dispatch:auto"},
    {"ticket.*.pr.opened", "pr:auto"},
    {"ticket.*.branch.push", "rework:auto"},
    {"ticket.*.pr.merged", "pr:auto"},
    {"ticket.*.agent.attention.*", "attention:auto"},
    {"ticket.*.agent.paused", "attention:auto"},
    {"ticket.*.agent.error.tokens_exhausted", "attention:auto"},
    {"ticket.*.agent.retry_exhausted", "attention:auto"},
    {"ticket.*.pr.parked_ready", "attention:auto"},
    {"ticket.*.ci.passed", "ci:auto"},
    {"ticket.*.ci.failed", "ci:auto"},
    {"ticket.*.pr.ready_for_review", "pr:auto"},
    # Allowed-contributor intake (#2957): identifier-only, author id attached.
    {"ticket.*.issue.opened.allowed_contributor", "intake:auto"}
  ]

  @spec defaults() :: [{String.t(), String.t()}]
  def defaults, do: @defaults

  @spec patterns() :: [String.t()]
  def patterns, do: Enum.map(@defaults, &elem(&1, 0))

  @spec allowlisted?(String.t()) :: boolean()
  def allowlisted?(pattern) when is_binary(pattern) do
    String.starts_with?(pattern, "executor.") or
      pattern in patterns() or
      Enum.any?(patterns(), &narrowing_of?(pattern, &1)) or
      ticket_narrowing?(pattern)
  end

  defp ticket_narrowing?("ticket." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [ticket, suffix] ->
        ticket != "*" and ticket != "#" and Regex.match?(~r/\A[0-9]+\z/, ticket) and suffix == "#"

      _ ->
        false
    end
  end

  defp ticket_narrowing?(_pattern), do: false

  # Requested bindings may use wildcards where every possible match remains
  # inside a reviewed binding. In particular, a concrete ticket prefix can
  # safely narrow one of the ticket-wide reviewed patterns.
  defp narrowing_of?(requested, reviewed) do
    requested_segments = String.split(requested, ".")
    reviewed_segments = String.split(reviewed, ".")
    pattern_subset?(requested_segments, reviewed_segments)
  end

  defp pattern_subset?([], []), do: true
  defp pattern_subset?(["#"], ["#"]), do: true
  defp pattern_subset?(["#" | _], ["#" | _]), do: false
  defp pattern_subset?(["#" | _], _), do: false
  defp pattern_subset?(_, ["#" | _]), do: true
  defp pattern_subset?([], _), do: false
  defp pattern_subset?(_, []), do: false
  defp pattern_subset?(["*" | rest], ["*" | reviewed]), do: pattern_subset?(rest, reviewed)
  defp pattern_subset?(["*" | rest], [literal | reviewed]) when literal not in ["*", "#"], do: pattern_subset?(rest, reviewed)
  defp pattern_subset?([literal | rest], ["*" | reviewed]) when literal not in ["*", "#"], do: pattern_subset?(rest, reviewed)
  defp pattern_subset?([literal | rest], [literal | reviewed]) when literal not in ["*", "#"], do: pattern_subset?(rest, reviewed)
  defp pattern_subset?(_, _), do: false

  @spec reconcile() :: :ok | {:error, term()}
  def reconcile, do: ExecutorEvents.reconcile_subscriptions(@defaults)
end
