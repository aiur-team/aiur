defmodule Aiur.BuildOrder.Features.LabelWriterTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildOrder.Features
  alias Aiur.BuildOrder.Features.LabelProjection, as: Projection
  alias Aiur.TestSupport.FeatureLabelFixture, as: F
  setup do: F.setup()

  test "minute cap includes ensure and defers the remaining writes", ctx do
    F.join(ctx, Enum.to_list(1..30))
    pid = F.start(ctx)
    assert length(F.calls()) == 20
    assert F.sync(pid).pending == 11
    F.tick(pid)
    assert length(F.calls()) == 20
    F.advance(ctx, 60)
    F.tick(pid)
    assert length(F.calls()) == 31
    assert F.sync(pid).pending == 0
    assert Enum.count(F.calls(), &match?({:ensure, _}, &1)) == 1
  end

  test "hour cap holds 250 pending at 200 writes until the hour advances", ctx do
    F.join(ctx, Enum.to_list(1..250))
    pid = F.start(ctx, tracker: F.NoEnsureTracker, max_writes_per_minute: 60)

    for _ <- 1..4 do
      F.advance(ctx, 60)
      F.tick(pid)
    end

    assert length(F.calls()) == 200
    assert F.sync(pid).pending == 50
    F.advance(ctx, 3_360)
    F.tick(pid)
    assert length(F.calls()) == 250
    assert F.sync(pid).pending == 0
  end

  test "local holds pause without attempts and registry signals do not bypass the pause", ctx do
    F.join(ctx, [12, 13])
    F.results(:add, [{:error, {:github, :local_hold, %{}}}])
    pid = F.start(ctx)
    assert F.sync(pid).writes == :paused
    assert F.entries(ctx)[{"auth", 12}].attempts == 0
    F.join(ctx, 14)
    F.sync(pid)
    assert length(F.calls()) == 2
    F.tick(pid)
    assert length(F.calls()) == 5
    assert F.sync(pid).writes == :running
  end

  test "held ensure pauses repeatedly without exhausting retries", ctx do
    F.join(ctx, 12)
    F.results(:ensure, List.duplicate({:error, {:github_api_status, 429, "feature:auth"}}, 5))
    pid = F.start(ctx)
    for _ <- 1..4, do: F.tick(pid)
    assert length(F.calls()) == 5
    assert F.sync(pid).writes == :paused
    assert F.entries(ctx)[{"auth", 12}].state == :pending_label
    assert F.entries(ctx)[{"auth", 12}].attempts == 0
  end

  test "five errors stop automatic retries; explicit retry resets", ctx do
    F.join(ctx, 12)
    F.results(:add, List.duplicate({:error, {:github, :http, %{status: 500}}}, 5))
    pid = F.start(ctx)
    for _ <- 1..4, do: F.tick(pid)
    assert F.entries(ctx)[{"auth", 12}].state == :failed
    assert F.entries(ctx)[{"auth", 12}].attempts == 5
    F.tick(pid)
    assert length(F.calls()) == 6
    assert [{"auth", 12, reason}] = F.sync(pid).failed
    assert reason =~ "500"
    assert Projection.retry([{"auth", 12}], server: pid) == :ok
    assert F.states(pid, [12]) == {:ok, %{12 => :pending_label}}
    F.tick(pid)
    assert F.states(pid, [12]) == {:ok, %{12 => :labelled}}
  end

  test "failed deletions stay failed across ticks and explicit retry restores deletion", ctx do
    F.join(ctx, 12)
    pid = F.start(ctx)
    F.observe(ctx, 12, ["feature:auth"])
    F.tick(pid)
    F.results(:remove, List.duplicate({:error, {:github, :http, %{status: 500}}}, 5))
    F.leave(ctx, 12)
    F.sync(pid)
    for _ <- 1..5, do: F.tick(pid)
    assert F.entries(ctx)[{"auth", 12}].state == :failed
    count = length(F.calls())
    F.tick(pid)
    assert length(F.calls()) == count
    assert Projection.retry([{"auth", 12}], server: pid) == :ok
    assert F.entries(ctx)[{"auth", 12}].state == :pending_unlabel
    F.tick(pid)
    assert List.last(F.calls()) == {:remove, "12", "feature:auth"}
    assert F.entries(ctx)[{"auth", 12}].state == :unlabelled
  end

  test "gone issues fail on the first add and failed items retry once on boot", ctx do
    F.join(ctx, 12)
    F.results(:add, [{:error, {:github, :http, %{status: 404}}}])
    pid = F.start(ctx)
    assert F.states(pid, [12]) == {:ok, %{12 => :failed}}
    assert F.entries(ctx)[{"auth", 12}].attempts == 1
    stop_supervised!(Projection)
    restarted = F.start(ctx)
    assert F.states(restarted, [12]) == {:ok, %{12 => :labelled}}
    assert Enum.count(F.calls(), &match?({:add, _, _}, &1)) == 2
  end

  test "unsupported stops writes and leaves pending membership intact", ctx do
    F.join(ctx, [12, 13])
    F.results(:add, [{:error, :unsupported}])
    pid = F.start(ctx)
    assert F.sync(pid).tracker == :unsupported
    assert F.sync(pid).pending == 2
    F.tick(pid)
    assert length(F.calls()) == 2
    assert F.states(pid, [12, 13]) == {:ok, %{12 => :pending_label, 13 => :pending_label}}
  end

  test "prefix collision disables subscription, reconciliation and writes", ctx do
    F.join(ctx, 12)
    pid = F.start(ctx, label_prefix: "feature")
    assert F.sync(pid).tracker == :prefix_collision
    F.observe(ctx, 13, ["feature:auth"])
    F.sync(pid)
    assert F.calls() == []
    assert Features.owner(13, server: ctx.features) == :none
    refute File.exists?(ctx.path)
  end
end
