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
