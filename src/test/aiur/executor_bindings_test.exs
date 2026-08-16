defmodule Aiur.ExecutorBindingsTest do
  use Aiur.TestSupport

  alias Aiur.Config.Paths
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

  test "reconciliation prunes stale auto entries but preserves manual entries" do
    path = Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.executor.subscriptions.json")

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
