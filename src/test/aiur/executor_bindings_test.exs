defmodule Aiur.ExecutorBindingsTest do
  use Aiur.TestSupport

  alias Aiur.Executor.StatePaths
  alias Aiur.ExecutorBindings
  alias Aiur.ExecutorEvents
  alias Aiur.JsonStore

  test "every default is allowlisted and reconciliation is idempotent" do
    assert Enum.all?(ExecutorBindings.patterns(), &(ExecutorEvents.validate_binding_topic(&1) == :ok))

    assert :ok = ExecutorBindings.reconcile()
    first = ExecutorEvents.subscription_entries()
    assert :ok = ExecutorBindings.reconcile()
    assert ExecutorEvents.subscription_entries() == first

    assert Enum.all?(first, &is_integer(&1["subscription_created_at_event_id"]))
  end

  test "the Executor is subscribed to allowed-contributor intake wakes only (#2957)" do
    assert "ticket.*.issue.opened.allowed_contributor" in ExecutorBindings.patterns()
    assert ExecutorBindings.allowlisted?("ticket.7.issue.opened.allowed_contributor")
    # Plain issue traffic is not an Executor wake: only the intake topic is.
    refute ExecutorBindings.allowlisted?("ticket.7.issue.opened")
    refute ExecutorBindings.allowlisted?("ticket.7.issue.commented")
  end

  test "the Executor listens for human-review handoff wakes" do
    pattern = "ticket.*.agent.handoff.human_review"
    assert pattern in ExecutorBindings.patterns()
    assert ExecutorBindings.allowlisted?("ticket.42.agent.handoff.human_review")
  end

  test "allowlist accepts exact instances but rejects broader candidate wildcards" do
    assert ExecutorBindings.allowlisted?("ticket.42.pr.opened")
    assert ExecutorBindings.allowlisted?("ticket.*.pr.opened")
    assert ExecutorBindings.allowlisted?("executor.#")
    assert ExecutorBindings.allowlisted?("executor.notice.*")
    assert ExecutorBindings.allowlisted?("ticket.3028.agent.attention.*")

    refute ExecutorBindings.allowlisted?("ticket.#.pr.opened")
    refute ExecutorBindings.allowlisted?("ticket.*.#")
    refute ExecutorBindings.allowlisted?("system.*.capacity_starved")
  end

  test "reconciliation prunes stale auto entries but preserves manual entries" do
    path = StatePaths.subscriptions_path()

    JsonStore.write!(path, %{
      "subscribed_to" => [
        %{"topic" => "ticket.*.old.event", "reason" => "old:auto", "subscription_created_at_event_id" => 1},
        %{"topic" => "ticket.42.pr.opened", "reason" => "manual:executor", "subscription_created_at_event_id" => 2}
      ],
      "last_seen_event_id" => 9
    })

    assert :ok = ExecutorBindings.reconcile()
    entries = ExecutorEvents.subscription_entries()
    refute Enum.any?(entries, &(&1["topic"] == "ticket.*.old.event"))
    assert Enum.any?(entries, &(&1["topic"] == "ticket.42.pr.opened" and &1["reason"] == "manual:executor"))
    assert ExecutorEvents.last_seen_event_id() == 9
  end
end
