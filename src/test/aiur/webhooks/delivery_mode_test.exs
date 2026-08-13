defmodule Aiur.Webhooks.DeliveryModeTest do
  use ExUnit.Case, async: true

  alias Aiur.Webhooks.DeliveryMode

  @repo "aiur-team/aiur"
  @threshold_ms 900_000

  defp at(seconds), do: DateTime.add(~U[2026-08-09 12:00:00Z], seconds, :second)

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

    test "silence past the threshold degrades to polling" do
      {proven, :proven} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_delivery(at(0))
      {degraded, transition} = DeliveryMode.sweep(proven, at(901), @threshold_ms)

      assert transition == :degraded
      assert degraded.state == :degraded
      assert DeliveryMode.transport(degraded) == :polling
      assert DeliveryMode.polling_reason(degraded) == :degraded_from_silence
      assert degraded.degraded_at == at(901)
    end

    test "silence inside the threshold changes nothing" do
      {proven, :proven} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_delivery(at(0))

      assert {^proven, :none} = DeliveryMode.sweep(proven, at(899), @threshold_ms)
    end

    test "degradation fires once, not on every subsequent sweep" do
      {proven, :proven} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_delivery(at(0))
      {degraded, :degraded} = DeliveryMode.sweep(proven, at(901), @threshold_ms)

      assert {^degraded, :none} = DeliveryMode.sweep(degraded, at(5000), @threshold_ms)
    end

    test "a resumed delivery recovers webhook mode with no other input" do
      {proven, :proven} = @repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_delivery(at(0))
      {degraded, :degraded} = DeliveryMode.sweep(proven, at(901), @threshold_ms)
      {recovered, transition} = DeliveryMode.record_delivery(degraded, at(1000))

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
end
