defmodule Aiur.Orchestrator.StatusReasonTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.StatusReason

  test "renders all operator-visible idle and pause classifications" do
    assert StatusReason.render(:awaiting_dispatch) == "awaiting-dispatch"
    assert StatusReason.render(:prewarm_blocked) == "prewarm-blocked"
    assert StatusReason.render({:latched, 20, 20}) == "latched 20/20"
    assert StatusReason.render(StatusReason.for_retry("tracker 403", 240_000)) == "transient: tracker 403, retry ~4m"
    assert StatusReason.render(StatusReason.for_pause(:operator_pause)) == "operator"
  end
end
