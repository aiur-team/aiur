defmodule Aiur.Events.UniversalSubscriptionsTest do
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.Events.{SubscriptionStore, UniversalSubscriptions}
  alias Aiur.Workflow

  test "attaches the complete universal topic set" do
    identifier = "universal-#{System.unique_integer([:positive])}"

    try do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_base_branch: "trunk")

      :ok = UniversalSubscriptions.attach(identifier)

      assert SubscriptionStore.snapshot(identifier).subscribed_to
             |> Enum.map(&{&1["topic"], &1["reason"]})
             |> Enum.sort() == [
               {"system.config.base_branch.changed", "config_change:auto"},
               {"system.trunk.branch.push", "base_branch:auto"},
               {"ticket.#{identifier}.ci.failed", "ci_status:auto"},
               {"ticket.#{identifier}.ci.passed", "ci_status:auto"},
               {"ticket.#{identifier}.issue.commented", "own_comments:auto"},
               {"ticket.#{identifier}.operator.progress_request", "progress_checkin:auto"},
               {"ticket.#{identifier}.pr.review_comment", "own_comments:auto"}
             ]
    after
      :ok = SubscriptionStore.stop(identifier)
    end
  end

  test "reconcile_base_branch prunes a stale base_branch:auto topic and adds the current one" do
    identifier = "universal-reconcile-#{System.unique_integer([:positive])}"
    path = Workflow.workflow_file_path()

    try do
      write_workflow_file!(path, tracker_base_branch: "main")
      :ok = UniversalSubscriptions.attach(identifier)

      # A stale topic from a retired base, added directly — as if the store was
      # parked before the change and never heard the announcement.
      :ok = SubscriptionStore.add_subscription(identifier, "system.retired.branch.push", "base_branch:auto")

      assert ["system.retired.branch.push"] = UniversalSubscriptions.reconcile_base_branch(identifier)

      topics = Enum.map(SubscriptionStore.snapshot(identifier).subscribed_to, & &1["topic"])
      assert "system.main.branch.push" in topics
      refute "system.retired.branch.push" in topics
    after
      :ok = SubscriptionStore.stop(identifier)
    end
  end

  test "reconcile_base_branch leaves manual subscriptions on the same topic untouched" do
    identifier = "universal-reconcile-manual-#{System.unique_integer([:positive])}"
    path = Workflow.workflow_file_path()

    try do
      write_workflow_file!(path, tracker_base_branch: "main")
      :ok = UniversalSubscriptions.attach(identifier)

      # A manual claim on the retired topic must survive reconcile: removal is
      # scoped by the `base_branch:auto` reason.
      :ok =
        SubscriptionStore.add_subscription(identifier, "system.retired.branch.push", "manual:operator")

      assert [] = UniversalSubscriptions.reconcile_base_branch(identifier)

      topics = Enum.map(SubscriptionStore.snapshot(identifier).subscribed_to, & &1["topic"])
      assert "system.retired.branch.push" in topics
    after
      :ok = SubscriptionStore.stop(identifier)
    end
  end

  test "reconcile_subscribed_to drops stale base_branch:auto entries and preserves others" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_base_branch: "main")

    subscribed_to = [
      %{
        "topic" => "system.retired.branch.push",
        "reason" => "base_branch:auto",
        "subscription_created_at_event_id" => 1
      },
      %{
        "topic" => "ticket.9.issue.commented",
        "reason" => "own_comments:auto",
        "subscription_created_at_event_id" => 2
      }
    ]

    result = UniversalSubscriptions.reconcile_subscribed_to(subscribed_to)
    topics = Enum.map(result, & &1["topic"])

    assert "system.main.branch.push" in topics
    refute "system.retired.branch.push" in topics
    assert "ticket.9.issue.commented" in topics
    assert length(result) == 2
  end

  test "attach reconciles a superseded base_branch:auto topic to the current base" do
    identifier = "universal-reconcile-attach-#{System.unique_integer([:positive])}"
    path = Workflow.workflow_file_path()

    try do
      write_workflow_file!(path, tracker_base_branch: "trunk")
      :ok = UniversalSubscriptions.attach(identifier)

      # The base changed while the ticket was parked; the next attach must
      # prune the retired branch's push topic and subscribe the new one.
      write_workflow_file!(path, tracker_base_branch: "main")
      :ok = UniversalSubscriptions.attach(identifier)

      topics = Enum.map(SubscriptionStore.snapshot(identifier).subscribed_to, & &1["topic"])
      assert "system.main.branch.push" in topics
      refute "system.trunk.branch.push" in topics
    after
      :ok = SubscriptionStore.stop(identifier)
    end
  end

  test "subscription store failures are non-fatal" do
    log =
      capture_log(fn ->
        assert :ok = UniversalSubscriptions.attach("wake-issue", FailingSubscriptionStore)
      end)

    assert log =~ "UniversalSubscriptions.add_subscription_failed"
    assert log =~ "ticket.wake-issue.operator.progress_request"
  end

  defmodule FailingSubscriptionStore do
    def attach(_identifier), do: :ok

    def add_subscription(_identifier, topic, _reason) do
      if String.ends_with?(topic, ".operator.progress_request") do
        exit(:subscription_store_down)
      else
        :ok
      end
    end
  end
end
