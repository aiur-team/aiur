defmodule Aiur.ExecutorBindings do
  @moduledoc false

  alias Aiur.Events.Topic
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
    {"ticket.*.pr.ready_for_review", "pr:auto"}
  ]

  @spec defaults() :: [{String.t(), String.t()}]
  def defaults, do: @defaults

  @spec patterns() :: [String.t()]
  def patterns, do: Enum.map(@defaults, &elem(&1, 0))

  @spec allowlisted?(String.t()) :: boolean()
  def allowlisted?(pattern) when is_binary(pattern) do
    String.starts_with?(pattern, "executor.") or
      pattern in patterns() or
      (not wildcard_pattern?(pattern) and Enum.any?(patterns(), &Topic.matches?(&1, pattern)))
  end

  defp wildcard_pattern?(pattern), do: pattern |> String.split(".") |> Enum.any?(&(&1 in ["*", "#"]))

  @spec reconcile() :: :ok | {:error, term()}
  def reconcile, do: ExecutorEvents.reconcile_subscriptions(@defaults)
end
