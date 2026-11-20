defmodule Aiur.BuildOrder.Features.ConfirmationLabelProjectionTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildOrder.Features
  alias Aiur.BuildOrder.Features.LabelProjection
  alias Aiur.TestSupport.FeatureLabelFixture, as: F

  setup do
    assert :ok = Aiur.TestSupport.ensure_pubsub_running()
    F.setup()
  end

  test "confirm before projection starts stays held through replay and explicit release", ctx do
    assert {:ok, _} = F.join(ctx, 12, "backfill-agent")
    assert {:ok, _} = Features.confirm("auth", [12], F.meta(ctx))
    assert {:ok, %{confirmed: true, source: "cli:test", joined_source: "backfill-agent"}} = Features.owner(12, server: ctx.features)
    replay = start_supervised!({Features, name: nil, state_dir: Path.join(ctx.dir, "registry"), clock: fn -> F.now(ctx) end, general_epics: []}, id: :replayed_features)
    assert {:ok, %{confirmed: true, source: "cli:test", joined_source: "backfill-agent"}} = Features.owner(12, server: replay)
    projection = F.start(ctx, feature_options: [server: replay])
    assert F.states(projection, [12]) == {:ok, %{12 => :held_backfill}}
    assert F.calls() == []
    times = %{written_at: nil, seen_at: F.now(ctx)}
    assert LabelProjection.mark_labelled("auth", 12, times, server: projection) == :ok
    assert F.states(projection, [12]) == {:ok, %{12 => :labelled}}
    F.tick(projection)
    assert F.states(projection, [12]) == {:ok, %{12 => :labelled}}
    assert F.calls() == []
  end
end
