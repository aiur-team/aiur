defmodule Aiur.Orchestrator.StatusReasonTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.StatusReason

  test "renders all operator-visible idle and pause classifications" do
    assert StatusReason.render(:awaiting_dispatch) == "awaiting-dispatch"
    assert StatusReason.render(:prewarm_blocked) == "prewarm-blocked"
    assert StatusReason.render(:orphaned_claim) == "orphaned claim: no live agent"
    assert StatusReason.render(:stale_claim) == "stale in-progress claim: no live agent"
    assert StatusReason.render(:workspace_ownership_waiting) == "workspace ownership held; awaiting safe release"

    assert StatusReason.render({:workspace_ownership_waiting, 9012, :not_recorded}) ==
             "workspace ownership held (generation 9012): unknown provider; exit proof not recorded"

    assert StatusReason.render({:workspace_ownership_waiting, 9012, :boot_changed_release_pending}) ==
             "workspace ownership held (generation 9012): local host reboot proved provider exit; audit/release pending, retry with aiur workspace-recover <ticket> <generation>"

    assert StatusReason.render({:latched, 20, 20}) == "latched 20/20"
    assert StatusReason.render(StatusReason.for_retry("tracker 403", 240_000)) == "transient: tracker 403, retry ~4m"
    assert StatusReason.render(StatusReason.for_pause(:operator_pause)) == "operator"
    assert StatusReason.render(StatusReason.for_pause(:github_budget_hold)) == "GitHub budget hold; automatic retry"
  end

  test "keeps a lifetime latch visible while prewarm is blocked" do
    assert {:latched, 20, 20} = StatusReason.for_idle(true, :lifetime, 20, 20)
  end
end
