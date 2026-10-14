defmodule Aiur.BuildOrder.Features.LabelProjectionTest do
  use ExUnit.Case, async: false
  alias Aiur.Application, as: AiurApp
  alias Aiur.BuildOrder.{Component, Features, History}
  alias Aiur.BuildOrder.Features.LabelProjection, as: Projection
  alias Aiur.TestSupport.FeatureLabelFixture, as: F
  setup do: F.setup()

  test "registry and History subscriptions reconcile without a periodic tick", ctx do
    pid = F.start(ctx)
    assert :ok = Features.subscribe()
    assert {:ok, _} = F.join(ctx, 12)
    assert_receive {:feature_label_write, {:add, "12", "feature:auth"}}, 2_000
    assert F.states(pid, [12]) == {:ok, %{12 => :labelled}}
    # Consume the CLI change before observing the label-driven join.
    assert_receive {:build_order_features_changed, %{changed: [12]}}, 2_000
    assert {:ok, _} = F.observe(ctx, 13, ["feature:auth"])
    assert_receive {:build_order_features_changed, %{changed: [13]}}, 2_000
    assert {:ok, %{feature: "auth", source: "label:unknown"}} = Features.owner(13, server: ctx.features)
  end

  test "registry joins ensure once, write labels and persist; echoes do not write again", ctx do
    F.join(ctx, [12, 13])
    pid = F.start(ctx)
    assert F.calls() == [{:ensure, ["feature:auth"]}, {:add, "12", "feature:auth"}, {:add, "13", "feature:auth"}]
    assert F.states(pid, [12, 13]) == {:ok, %{12 => :labelled, 13 => :labelled}}
    F.advance(ctx, 10)
    F.observe(ctx, 12, ["feature:auth"])
    F.tick(pid)
    assert length(F.calls()) == 3
    assert F.entries(ctx)[{"auth", 12}].written_at == DateTime.add(F.now(ctx), -10)
    assert Bitwise.band(File.stat!(ctx.path).mode, 0o777) == 0o600
  end

  test "History signals join and remove with label provenance and settle safety", ctx do
    pid = F.start(ctx)
    F.observe(ctx, 12, ["feature:auth"])
    # A synchronous barrier after the signal: no direct mutation of projection state.
    F.tick(pid)
    assert {:ok, %{feature: "auth", source: "label:unknown", actor: "unknown"}} = Features.owner(12, server: ctx.features)
    assert F.calls() == []
    F.advance(ctx, 30)
    F.observe(ctx, 12, [])
    F.tick(pid)
    assert {:ok, %{feature: "auth"}} = Features.owner(12, server: ctx.features)
    F.advance(ctx, 100)
    F.observe(ctx, 12, [])
    F.tick(pid)
    assert Features.owner(12, server: ctx.features) == :none
    assert F.entries(ctx)[{"auth", 12}].state == :unlabelled
    assert {:ok, journal} = Features.journal("auth", server: ctx.features)
    assert List.last(journal).source == "label:unknown"
    assert List.last(journal).type == "member.removed"
    assert F.calls() == []
  end

  test "CLI leave cannot be rejoined by a stale label; move deletes old label", ctx do
    F.join(ctx, 12)
    pid = F.start(ctx)
    F.observe(ctx, 12, ["feature:auth"])
    F.tick(pid)
    F.results(:remove, [{:error, {:github, :local_hold, %{}}}])
    F.leave(ctx, 12)
    F.sync(pid)
    F.tick(pid)
    assert Features.owner(12, server: ctx.features) == :none
    assert F.entries(ctx)[{"auth", 12}].state in [:pending_unlabel, :unlabelled]
    F.join(ctx, 12, "cli:test", "other")
    F.tick(pid)
    assert {:ok, %{feature: "other"}} = Features.owner(12, server: ctx.features)
    assert {:add, "12", "feature:other"} in F.calls()
    assert {:remove, "12", "feature:auth"} in F.calls()
  end

  test "human label moves unconfirmed backfill and preserves confirmed-owner conflict", ctx do
    F.join(ctx, 12, "backfill-agent")
    F.join(ctx, 13)
    pid = F.start(ctx)
    F.observe(ctx, 12, ["feature:other"])
    F.observe(ctx, 13, ["feature:other", "feature:zzz"])
    F.tick(pid)
    assert {:ok, %{feature: "other", source: "label:unknown", confirmed: true}} = Features.owner(12, server: ctx.features)
    assert {:ok, %{feature: "auth"}} = Features.owner(13, server: ctx.features)
    status = F.sync(pid)
    assert {13, ["auth", "other"]} in status.conflicts
    assert {13, "zzz"} in status.unregistered
    refute {:remove, "13", "feature:other"} in F.calls()
  end

  test "held backfill releases only through mark_labelled and imported members remain exempt", ctx do
    F.join(ctx, 12, "backfill-agent")
    F.join(ctx, 13, "import:build-order")
    pid = F.start(ctx)
    F.observe(ctx, 12, ["feature:auth"])
    F.observe(ctx, 13, ["feature:auth"])
    F.tick(pid)
    assert F.states(pid, [12, 13]) == {:ok, %{12 => :held_backfill, 13 => :exempt}}
    assert F.calls() == []
    times = %{written_at: nil, seen_at: F.now(ctx)}
    assert Projection.mark_labelled("auth", 12, times, server: pid) == :ok
    assert F.states(pid, [12]) == {:ok, %{12 => :labelled}}
    assert Projection.mark_labelled("auth", 12, times, server: pid) == {:error, :not_held}
    assert Projection.mark_labelled("other", 12, times, server: pid) == {:error, {:not_member, [12]}}
    assert Projection.mark_labelled("auth", 99, times, server: pid) == {:error, {:not_member, [99]}}
    assert F.entries(ctx)[{"auth", 12}].seen_at == times.seen_at
  end

  test "state survives restart without repeating label writes", ctx do
    F.join(ctx, 12)
    pid = F.start(ctx)
    assert F.states(pid, [12]) == {:ok, %{12 => :labelled}}
    stop_supervised!(Projection)
    restarted = F.start(ctx)
    assert F.states(restarted, [12]) == {:ok, %{12 => :labelled}}
    assert F.calls() == [{:ensure, ["feature:auth"]}, {:add, "12", "feature:auth"}]
  end

  test "corrupt state is quarantined and rebuilt from positive observations", ctx do
    F.join(ctx, 12)
    F.observe(ctx, 12, ["feature:auth"])
    File.write!(ctx.path, "{not json")
    pid = F.start(ctx)
    assert F.states(pid, [12]) == {:ok, %{12 => :labelled}}
    assert [_] = Path.wildcard(ctx.path <> ".corrupt-*")
    assert F.calls() == []
  end

  test "lost state rebuilds removal tombstones from the journal", ctx do
    F.join(ctx, 12)
    F.leave(ctx, 12)
    F.observe(ctx, 12, ["feature:auth"])
    F.results(:remove, [{:error, {:github, :local_hold, %{}}}])
    pid = F.start(ctx)
    assert Features.owner(12, server: ctx.features) == :none
    assert F.entries(ctx)[{"auth", 12}].state == :pending_unlabel
    assert F.sync(pid).writes == :paused
    assert {:remove, "12", "feature:auth"} in F.calls()
    refute {:add, "12", "feature:auth"} in F.calls()
  end

  test "unreadable registry and failed persistence report errors instead of zero pending", ctx do
    pid = F.start(ctx, feature_options: [server: :missing_label_registry])
    assert F.sync(pid) == {:error, :registry_unavailable}
    stop_supervised!(Projection)
    F.join(ctx, 12)
    File.mkdir_p!(ctx.path)
    pid = F.start(ctx)
    assert F.sync(pid) == {:error, :projection_state_unavailable}
    assert F.calls() == []
  end

  test "stale History does not remove membership but registry writes remain possible", ctx do
    F.join(ctx, 12)
    pid = F.start(ctx)
    stop_supervised!(Aiur.TestSupport.FeatureLabelFixture.History)
    F.join(ctx, 13)
    F.tick(pid)
    assert {:add, "13", "feature:auth"} in F.calls()
    assert F.sync(pid).observation == :not_running
    assert F.states(pid, [12, 13]) == {:ok, %{12 => :labelled, 13 => :labelled}}
    assert History.health(server: ctx.history).state == :unavailable
  end

  test "supervision is recording-gated and follows registry and History" do
    specs = AiurApp.child_specs(recording?: true, interactive_cli?: false, headless?: true, dashboard?: false)

    mods =
      Enum.map(specs, fn
        {module, _} -> module
        %{id: id} -> id
        module -> module
      end)

    assert Enum.find_index(mods, &(&1 == Projection)) > Enum.find_index(mods, &(&1 == Features))
    assert Enum.find_index(mods, &(&1 == Projection)) > Enum.find_index(mods, &(&1 == History))
    assert List.last(mods) == Projection
    refute Projection in Component.child_specs(:label_projection, recording?: false)
  end
end
