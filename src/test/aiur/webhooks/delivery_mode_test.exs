defmodule Aiur.Webhooks.DeliveryModeTest do
  use ExUnit.Case, async: true

  alias Aiur.Webhooks.DeliveryMode

  @repo "aiur-team/aiur"
  @threshold_ms 900_000

  defp at(seconds), do: DateTime.add(~U[2026-08-09 12:00:00Z], seconds, :second)

  # A proven repo whose silence is corroborated: the poller published an event
  # a full threshold after the last delivery, so a delivery was demonstrably
  # owed and never came.
  defp silent_with_activity do
    {proven, :proven} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_delivery(at(0))
    {corroborated, :none} = DeliveryMode.record_activity(proven, at(901))
    corroborated
  end

  describe "configuration never proves a webhook" do
    test "an unconfigured repo is never_configured and polls" do
      mode = DeliveryMode.new(@repo)

      assert mode.state == :never_configured
      assert DeliveryMode.transport(mode) == :polling
      assert DeliveryMode.polling_reason(mode) == :never_configured
    end

    test "configuring a repo only reaches configured_unproven" do
      mode = DeliveryMode.new(@repo, configured?: true)

      assert mode.state == :configured_unproven
      assert DeliveryMode.transport(mode) == :polling
      assert DeliveryMode.polling_reason(mode) == :configured_unproven
      refute DeliveryMode.webhook_backed?(mode)
    end

    test "a configured repo stays unproven no matter how long it is swept" do
      mode = DeliveryMode.new(@repo, configured?: true)

      {swept, transition} = DeliveryMode.sweep(mode, at(10 * @threshold_ms), @threshold_ms)

      assert swept.state == :configured_unproven
      assert transition == :none, "a repo that never delivered must not raise a degradation alert"
    end

    test "unconfiguring a proven repo discards the proof" do
      {proven, :proven} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_delivery(at(0))
      {unconfigured, :unconfigured} = DeliveryMode.configure(proven, false)

      assert unconfigured.state == :never_configured
      assert unconfigured.last_delivery_at == nil
      assert unconfigured.delivery_count == 0
      assert DeliveryMode.transport(unconfigured) == :polling
    end

    test "re-applying the same configuration is a no-op transition" do
      mode = DeliveryMode.new(@repo, configured?: true)

      assert {^mode, :none} = DeliveryMode.configure(mode, true)
    end
  end

  describe "deliveries prove, silence degrades, deliveries recover" do
    test "the first delivery proves the repo" do
      {proven, transition} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_delivery(at(0))

      assert transition == :proven
      assert proven.state == :webhook_backed
      assert DeliveryMode.transport(proven) == :webhook
      assert DeliveryMode.polling_reason(proven) == nil
      assert proven.last_delivery_at == at(0)
      assert proven.delivery_count == 1
    end

    test "a delivery on a never-configured repo proves it too" do
      {proven, :proven} = @repo |> DeliveryMode.new() |> DeliveryMode.record_delivery(at(0))

      assert proven.configured?, "a repo cannot deliver without a webhook"
      assert proven.state == :webhook_backed
    end

    test "silence corroborated by observed activity degrades to polling" do
      {degraded, transition} = DeliveryMode.sweep(silent_with_activity(), at(1802), @threshold_ms)

      assert transition == :degraded
      assert degraded.state == :degraded
      assert DeliveryMode.transport(degraded) == :polling
      assert DeliveryMode.polling_reason(degraded) == :degraded_from_silence
      assert degraded.degraded_at == at(1802)
    end

    test "silence inside the threshold changes nothing" do
      proven = silent_with_activity()

      assert {^proven, :none} = DeliveryMode.sweep(proven, at(899), @threshold_ms)
    end

    test "degradation fires once, not on every subsequent sweep" do
      {degraded, :degraded} = DeliveryMode.sweep(silent_with_activity(), at(1802), @threshold_ms)

      assert {^degraded, :none} = DeliveryMode.sweep(degraded, at(5000), @threshold_ms)
    end

    test "a resumed delivery recovers webhook mode with no other input" do
      {degraded, :degraded} = DeliveryMode.sweep(silent_with_activity(), at(1802), @threshold_ms)
      {recovered, transition} = DeliveryMode.record_delivery(degraded, at(2000))

      assert transition == :recovered
      assert recovered.state == :webhook_backed
      assert recovered.degraded_at == nil
      assert DeliveryMode.transport(recovered) == :webhook
    end

    test "a steady-state delivery reports no transition" do
      {proven, :proven} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_delivery(at(0))

      assert {%DeliveryMode{delivery_count: 2}, :none} = DeliveryMode.record_delivery(proven, at(10))
    end

    test "an out-of-order delivery never moves the silence clock backwards" do
      {proven, :proven} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_delivery(at(100))
      {reordered, :none} = DeliveryMode.record_delivery(proven, at(50))

      assert reordered.last_delivery_at == at(100)
      {_swept, :none} = DeliveryMode.sweep(reordered, at(900), @threshold_ms)
    end
  end

  describe "an idle repository is not a broken one" do
    test "a proven repo silent for hours with no observed activity never degrades" do
      {proven, :proven} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_delivery(at(0))

      assert {^proven, :none} = DeliveryMode.sweep(proven, at(100 * @threshold_ms), @threshold_ms),
             "GitHub sends no heartbeat, so silence alone is an idle repo — degrading on it alerts about a working webhook"
    end

    test "activity the last delivery already covers is not evidence of a miss" do
      {proven, :proven} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_delivery(at(0))
      # Poll lag: the poller observes an event the webhook delivered moments ago.
      {lagging, :none} = DeliveryMode.record_activity(proven, at(120))

      assert {^lagging, :none} = DeliveryMode.sweep(lagging, at(901), @threshold_ms),
             "activity inside one threshold of the last delivery is poll lag, not a lost delivery"
    end

    test "activity never moves backwards" do
      {proven, :proven} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_delivery(at(0))
      {ahead, :none} = DeliveryMode.record_activity(proven, at(901))
      {behind, :none} = DeliveryMode.record_activity(ahead, at(10))

      assert behind.last_activity_at == at(901)
    end

    test "recording activity can never promote a repo to webhook mode" do
      {mode, transition} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_activity(at(50))

      assert transition == :none
      assert mode.state == :configured_unproven
      assert DeliveryMode.transport(mode) == :polling
      assert mode.delivery_count == 0
    end
  end

  describe "configured but never delivered is its own diagnosis" do
    test "a configured repo with observed activity and no delivery ever is reported" do
      {mode, :none} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_activity(at(50))
      {reported, transition} = DeliveryMode.sweep(mode, at(901), @threshold_ms)

      assert transition == :never_delivered,
             "an ingress that was never publicly reachable must not look the same as a repo with no webhook"

      assert reported.state == :configured_unproven
      assert DeliveryMode.polling_reason(reported) == :configured_unproven
    end

    test "the never-delivered report fires once, not on every sweep" do
      {mode, :none} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_activity(at(50))
      {reported, :never_delivered} = DeliveryMode.sweep(mode, at(901), @threshold_ms)

      assert {^reported, :none} = DeliveryMode.sweep(reported, at(5000), @threshold_ms)
    end

    test "a configured repo with no observed activity stays quiet" do
      mode = DeliveryMode.new(@repo, configured?: true)

      assert {^mode, :none} = DeliveryMode.sweep(mode, at(10 * @threshold_ms), @threshold_ms)
    end

    test "an unconfigured repo is never reported as never-delivered" do
      {mode, :none} = @repo |> DeliveryMode.new() |> DeliveryMode.record_activity(at(50))

      assert {^mode, :none} = DeliveryMode.sweep(mode, at(901), @threshold_ms),
             "a repo with no webhook configured is a choice, not a fault"
    end

    test "a first delivery re-arms the report for a repo that later goes unproven again" do
      {mode, :none} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_activity(at(50))
      {reported, :never_delivered} = DeliveryMode.sweep(mode, at(901), @threshold_ms)
      {proven, :proven} = DeliveryMode.record_delivery(reported, at(1000))

      refute proven.never_delivered_reported?
    end
  end
end
