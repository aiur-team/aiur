defmodule Aiur.Webhooks.ModePresenterTest do
  use ExUnit.Case, async: true

  alias Aiur.Webhooks.{DeliveryMode, ModePresenter}

  @delivered_at ~U[2026-08-09 12:00:00Z]

  defp proven(repo) do
    {mode, :proven} = repo |> DeliveryMode.new(configured?: true) |> DeliveryMode.record_delivery(@delivered_at)
    mode
  end

  defp degraded(repo) do
    {corroborated, :none} = repo |> proven() |> DeliveryMode.record_activity(DateTime.add(@delivered_at, 1_800, :second))
    {mode, :degraded} = DeliveryMode.sweep(corroborated, DateTime.add(@delivered_at, 3_600, :second), 900_000)
    mode
  end

  test "a webhook-backed repo shows its mode, delivery time, and no reason" do
    row = ModePresenter.row(proven("aiur-team/aiur"))

    assert row.transport == :webhook
    assert row.mode_label == "webhook"
    assert row.last_delivery_at == @delivered_at
    assert row.last_delivery_label == "2026-08-09T12:00:00Z"
    assert row.polling_reason == nil
    assert row.reason_label == nil
    assert row.delivery_count == 1
  end

  test "the three reasons for polling stay distinguishable" do
    never = ModePresenter.row(DeliveryMode.new("aiur-team/never"))
    unproven = ModePresenter.row(DeliveryMode.new("aiur-team/unproven", configured?: true))
    fallen = ModePresenter.row(degraded("aiur-team/fallen"))

    assert Enum.all?([never, unproven, fallen], &(&1.transport == :polling))
    assert Enum.all?([never, unproven, fallen], &(&1.mode_label == "polling"))

    assert never.polling_reason == :never_configured
    assert never.reason_label == "no webhook configured"
    assert never.last_delivery_label == "never"

    assert unproven.polling_reason == :configured_unproven
    assert unproven.reason_label == "webhook configured but never delivered"
    assert unproven.last_delivery_label == "never"

    assert fallen.polling_reason == :degraded_from_silence
    assert fallen.reason_label == "degraded — deliveries went silent"
    assert fallen.last_delivery_at == @delivered_at, "a degraded repo must still show when it last delivered"
  end

  test "rows/1 renders a mixed fleet ordered by repo" do
    modes = [degraded("aiur-team/zeta"), DeliveryMode.new("aiur-team/alpha"), proven("aiur-team/mid")]

    rows = ModePresenter.rows(modes: modes)

    assert Enum.map(rows, & &1.repo) == ["aiur-team/alpha", "aiur-team/mid", "aiur-team/zeta"]
    assert Enum.map(rows, & &1.transport) == [:polling, :webhook, :polling]
  end

  test "rows/1 is empty when nothing is registered" do
    assert ModePresenter.rows(modes: []) == []
  end
end
