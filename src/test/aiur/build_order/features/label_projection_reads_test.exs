defmodule Aiur.BuildOrder.Features.LabelProjectionReadsTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildOrder.{Features, History}
  alias Aiur.BuildOrder.Features.LabelProjection
  alias Aiur.TestSupport.FeatureLabelFixture, as: F

  defmodule CountedHistory do
    @moduledoc false
    alias Aiur.BuildOrder.{History, ProviderHealth}
    def subscribe, do: History.subscribe()
    def snapshot(_opts), do: raise("projection must read ETS rows, never a History snapshot")

    def health(opts) do
      if Agent.get(opts[:availability], & &1), do: History.health(opts), else: ProviderHealth.new(:unknown, :unavailable, false, failure: :test_unavailable)
    end

    def numbers(opts) do
      send(opts[:observer], :history_numbers)

      case health(opts) do
        %{state: :healthy} -> History.numbers(opts)
        health -> {:error, health}
      end
    end

    def rows(numbers, opts) do
      send(opts[:observer], {:history_rows, Enum.sort(numbers)})

      case health(opts) do
        %{state: :healthy} -> History.rows(numbers, opts)
        health -> {:error, health}
      end
    end
  end

  defmodule FlakyFeatures do
    @moduledoc false
    alias Aiur.BuildOrder.Features
    def subscribe, do: Features.subscribe()
    def snapshot(opts), do: Features.snapshot(opts)
    def journal(slug, opts), do: Features.journal(slug, opts)
    def remove(slug, numbers, opts), do: Features.remove(slug, numbers, opts)

    def add(slug, numbers, opts) do
      attempt = Agent.get_and_update(opts[:attempts], fn n -> {n, n + 1} end)
      if attempt == 0, do: {:error, :temporarily_unavailable}, else: Features.add(slug, numbers, opts)
    end
  end

  setup do
    ctx = F.setup()
    availability = start_supervised!({Agent, fn -> true end}, id: :history_availability)
    options = [history: CountedHistory, history_options: [server: ctx.history, observer: self(), availability: availability]]
    Map.merge(ctx, %{availability: availability, options: options})
  end

  test "boot walks bounded ETS batches and ticks read only feature entries", ctx do
    events =
      for n <- 1..450 do
        labels =
          case n do
            12 -> ["feature:auth"]
            13 -> ["feature:other"]
            _ -> ["bug"]
          end

        %{number: n, observed_at: F.now(ctx), source: :poll, fields: %{labels: labels, labels_complete: true}}
      end

    assert {:ok, _} = History.apply(events, server: ctx.history)
    assert {:ok, _} = F.join(ctx, 12)
    pid = F.start(ctx, ctx.options)
    assert_receive :history_numbers, 1_000
    reads = reads()
    assert Enum.sort(Enum.uniq(List.flatten(reads))) == Enum.to_list(1..450)
    assert Enum.all?(reads, &(length(&1) <= 200))
    assert {:ok, %{12 => :labelled, 13 => :labelled}} = F.states(pid, [12, 13])
    refute Map.has_key?(:sys.get_state(pid), :rows)
    reads()

    F.tick(pid)
    assert reads() == [[12, 13]]
    refute_receive :history_numbers, 100

    assert {:ok, _} = F.observe(ctx, 451, ["feature:auth"])
    F.sync(pid)
    assert {:ok, %{feature: "auth", source: "label:unknown"}} = Features.owner(451, server: ctx.features)
    F.sync(pid)
    reads()
    F.tick(pid)
    assert reads() == [[12, 13, 451]]
    refute_receive :history_numbers, 100
  end

  test "queued History events coalesce changed numbers into one read", ctx do
    pid = F.start(ctx, ctx.options)
    reads()
    assert :ok = :sys.suspend(pid)
    assert {:ok, _} = F.observe(ctx, 20, ["bug"])
    assert {:ok, _} = F.observe(ctx, 21, ["bug"])
    send(pid, {:build_order_history_changed, %{changed: [20]}})
    assert :ok = :sys.resume(pid)
    F.sync(pid)
    assert reads() == [[20, 21]]
  end

  test "cached projection defers the initial full walk until History recovers", ctx do
    F.join(ctx, 12)
    pid = F.start(ctx, ctx.options)
    assert F.states(pid, [12]) == {:ok, %{12 => :labelled}}
    stop_supervised!(LabelProjection)
    assert_receive :history_numbers, 1_000
    reads()
    assert {:ok, _} = F.observe(ctx, 30, ["feature:other"])
    Agent.update(ctx.availability, fn _ -> false end)
    restarted = F.start(ctx, ctx.options)
    assert F.sync(restarted).observation == :unavailable
    assert Features.owner(30, server: ctx.features) == :none
    refute_receive :history_numbers, 100
    Agent.update(ctx.availability, fn _ -> true end)
    F.tick(restarted)
    assert_receive :history_numbers, 1_000
    assert {:ok, %{feature: "other", source: "label:unknown"}} = Features.owner(30, server: ctx.features)
  end

  test "registering an observed unknown slug rechecks that ticket", ctx do
    F.observe(ctx, 30, ["feature:new"])
    pid = F.start(ctx, ctx.options)
    assert {30, "new"} in F.sync(pid).unregistered
    reads()
    assert {:ok, _} = F.create(ctx, "new")
    F.sync(pid)
    assert {:ok, %{feature: "new", source: "label:unknown"}} = Features.owner(30, server: ctx.features)
    assert [30] in reads()
  end

  test "failed label-origin joins retry from known rechecks on a tick", ctx do
    attempts = start_supervised!({Agent, fn -> 0 end}, id: :feature_add_attempts)
    options = ctx.options ++ [features: FlakyFeatures, feature_options: [server: ctx.features, attempts: attempts]]
    pid = F.start(ctx, options)
    assert {:ok, _} = F.observe(ctx, 30, ["feature:auth"])
    F.sync(pid)
    assert Agent.get(attempts, & &1) == 1
    assert Features.owner(30, server: ctx.features) == :none
    reads()
    F.tick(pid)
    assert Agent.get(attempts, & &1) == 2
    assert {:ok, %{feature: "auth", source: "label:unknown"}} = Features.owner(30, server: ctx.features)
    assert [30] in reads()
  end

  defp reads(acc \\ []) do
    receive do
      {:history_rows, numbers} -> reads([numbers | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
