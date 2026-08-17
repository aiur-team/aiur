defmodule Aiur.CadenceFreshnessTest do
  @moduledoc """
  Freshness is derived from the cadence actually in force, at every cadence.

  A single-cadence test proves nothing about a derived threshold, so every
  assertion below runs at three: the pre-#2064 5s poll, the shipped 120s poll,
  and the 1200s an idle fleet actually polls at once `idle_widen_factor: 5.0`
  and `poll_widen_factor: 2.0` compose.

  Each case asserts both halves. Data younger than the cadence must not be
  called stale, and data genuinely older than it must still be called stale —
  a change that merely stopped reporting staleness would satisfy the first
  half alone and be a regression.
  """

  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.TicketHistoryProvider.Options, as: TicketHistoryOptions
  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.PollCadence
  alias AiurWeb.OperatorControlCenter.UnitsPresenter
  alias AiurWeb.OperatorControlCenter.UnitsRow.Sources

  @read_timeout_ms 15_000

  # base 5s / 120s / 1200s. The third is the idle-backoff cadence, not a
  # configured interval — freshness that reads the base would call a correctly
  # idling fleet stale for 90% of every cycle.
  @cadences [
    %{name: "5s poll", interval_ms: 5_000},
    %{name: "120s poll", interval_ms: 120_000},
    %{name: "1200s poll (idle backoff, factor=5.0x)", interval_ms: 1_200_000}
  ]

  setup do
    previous_ceiling = Application.get_env(:aiur, :snapshot_stale_age_ceiling_ms)
    Application.delete_env(:aiur, :snapshot_stale_age_ceiling_ms)
    PollCadence.forget_effective_interval_ms()

    on_exit(fn ->
      PollCadence.forget_effective_interval_ms()

      if is_nil(previous_ceiling) do
        Application.delete_env(:aiur, :snapshot_stale_age_ceiling_ms)
      else
        Application.put_env(:aiur, :snapshot_stale_age_ceiling_ms, previous_ceiling)
      end
    end)

    :ok
  end

  describe "SnapshotStore staleness ceiling" do
    test "a snapshot younger than the effective cadence is never stale" do
      for %{name: name, interval_ms: interval_ms} <- @cadences do
        :ok = PollCadence.publish_effective_interval_ms(interval_ms)
        orchestrator = start_orchestrator()

        # One whole cadence has not yet elapsed: the producer is not late.
        publish_aged(orchestrator, interval_ms - 1)

        assert {:current, _snapshot, metadata} = SnapshotStore.read(orchestrator, @read_timeout_ms),
               "#{name}: a snapshot #{interval_ms - 1}ms old was reported stale"

        assert metadata.reason == nil
      end
    end

    test "a snapshot older than two effective cadences is still reported stale" do
      for %{name: name, interval_ms: interval_ms} <- @cadences do
        :ok = PollCadence.publish_effective_interval_ms(interval_ms)
        orchestrator = start_orchestrator()

        ceiling_ms = SnapshotStore.stale_age_ceiling_ms()
        publish_aged(orchestrator, ceiling_ms + 1_000)

        assert {:stale, _snapshot, metadata} = SnapshotStore.read(orchestrator, @read_timeout_ms),
               "#{name}: a snapshot #{ceiling_ms + 1_000}ms old was reported current"

        assert metadata.reason == :snapshot_stalled
      end
    end

    test "the ceiling is two effective cadences, floored at the pre-#2064 value" do
      expected = [{5_000, 120_000}, {120_000, 240_000}, {1_200_000, 2_400_000}]

      for {interval_ms, ceiling_ms} <- expected do
        :ok = PollCadence.publish_effective_interval_ms(interval_ms)

        assert SnapshotStore.stale_age_ceiling_ms() == ceiling_ms
      end
    end

    test "an explicit application override still wins" do
      :ok = PollCadence.publish_effective_interval_ms(1_200_000)
      Application.put_env(:aiur, :snapshot_stale_age_ceiling_ms, 9_000)

      assert SnapshotStore.stale_age_ceiling_ms() == 9_000
    end
  end

  describe "dashboard reader tolerance" do
    test "widens with the cadence instead of staying at the configured 15s" do
      expected = [{5_000, @read_timeout_ms}, {120_000, 240_000}, {1_200_000, 2_400_000}]

      for {interval_ms, tolerance_ms} <- expected do
        :ok = PollCadence.publish_effective_interval_ms(interval_ms)

        assert PollCadence.snapshot_tolerance_ms(@read_timeout_ms) == tolerance_ms
      end
    end

    test "a backlogged orchestrator does not flap stale inside one cadence" do
      # The reported symptom: at a 120s poll the fixed 15s tolerance held for
      # ~87% of every cycle, so a healthy fleet announced staleness continuously
      # while the Orchestrator was merely busy.
      :ok = PollCadence.publish_effective_interval_ms(120_000)
      orchestrator = start_orchestrator()
      backlog(orchestrator, 5)
      publish_aged(orchestrator, 100_000)

      tolerance_ms = PollCadence.snapshot_tolerance_ms(@read_timeout_ms)

      assert {:current, _snapshot, metadata} = SnapshotStore.read(orchestrator, tolerance_ms)
      assert metadata.orchestrator_mailbox_depth == 5
      assert metadata.freshness_window_ms == 240_000

      # ...and the backlog path still fires once the producer is genuinely
      # behind its own cadence.
      publish_aged(orchestrator, 300_000)

      assert {:stale, _snapshot, stale_metadata} = SnapshotStore.read(orchestrator, tolerance_ms)
      assert stale_metadata.reason in [:snapshot_timeout, :snapshot_stalled]
    end

    test "a reader that demands zero tolerance still gets it" do
      # Correctness-critical reads must be able to refuse any staleness at all;
      # the cadence floor is a reader default, never an override.
      :ok = PollCadence.publish_effective_interval_ms(1_200_000)
      orchestrator = start_orchestrator()
      backlog(orchestrator, 1)
      publish_aged(orchestrator, 5)

      assert {:stale, _snapshot, metadata} = SnapshotStore.read(orchestrator, 0)
      assert metadata.reason == :snapshot_timeout
    end
  end

  describe "Units catalog fleet window" do
    test "an idle fleet keeps its rows instead of emptying the table" do
      status = fn age_seconds -> %{health: :healthy, freshness: %{status: :stale, age_seconds: age_seconds}} end

      # 600s old. At the shipped 1200s idle cadence that is not even one cycle.
      for %{name: name, interval_ms: interval_ms, usable?: usable?} <- [
            %{name: "5s poll", interval_ms: 5_000, usable?: false},
            %{name: "120s poll", interval_ms: 120_000, usable?: false},
            %{name: "1200s poll (idle backoff)", interval_ms: 1_200_000, usable?: true}
          ] do
        :ok = PollCadence.publish_effective_interval_ms(interval_ms)
        sources = Sources.normalize(%{status: status.(600)})

        assert Sources.current_status?(sources) == usable?,
               "#{name}: a 600s-old fleet view was #{if usable?, do: "dropped", else: "admitted"}"
      end
    end

    test "a genuinely old fleet view is still dropped at every cadence" do
      status = %{health: :healthy, freshness: %{status: :stale, age_seconds: 100_000}}

      for %{name: name, interval_ms: interval_ms} <- @cadences do
        :ok = PollCadence.publish_effective_interval_ms(interval_ms)

        refute Sources.current_status?(Sources.normalize(%{status: status})),
               "#{name}: a 100_000s-old fleet view was still admitted"
      end
    end

    test "the window is two effective cadences, floored at 300s" do
      expected = [{5_000, 300}, {120_000, 300}, {1_200_000, 2_400}]

      for {interval_ms, seconds} <- expected do
        :ok = PollCadence.publish_effective_interval_ms(interval_ms)

        assert Sources.fleet_stale_after_seconds() == seconds
      end
    end

    test "the catalog status agrees with the rows it admitted" do
      # `UnitsPresenter` and `UnitsRow.Sources` must read one window, or the
      # catalog can call itself ready over rows the projection dropped.
      # `:empty` is the healthy answer for a fleet with no agents; `:stale` is
      # the answer only when the fleet view behind it is judged degraded.
      :ok = PollCadence.publish_effective_interval_ms(1_200_000)
      assert catalog_status(600) == :empty

      :ok = PollCadence.publish_effective_interval_ms(5_000)
      assert catalog_status(600) == :stale

      # And a genuinely old fleet view is stale at the widest cadence too.
      :ok = PollCadence.publish_effective_interval_ms(1_200_000)
      assert catalog_status(100_000) == :stale
    end
  end

  describe "Build Order ticket history" do
    test "the configured value is a floor and the cadence raises it" do
      expected = [{5_000, 60_000}, {120_000, 240_000}, {1_200_000, 2_400_000}]

      for {interval_ms, stale_after_ms} <- expected do
        :ok = PollCadence.publish_effective_interval_ms(interval_ms)

        assert TicketHistoryOptions.new([]).stale_after_ms == stale_after_ms
      end
    end

    test "an operator raising the configured value above the cadence is honoured" do
      :ok = PollCadence.publish_effective_interval_ms(5_000)

      assert TicketHistoryOptions.new(stale_after_ms: 300_000).stale_after_ms == 300_000
    end
  end

  defp catalog_status(age_seconds) do
    payload = %{
      generated_at: "2026-08-17T12:00:00Z",
      provider_health: %{fleet: :ok, decisions: :ok},
      fleet: %{
        snapshot_freshness: %{status: :stale, age_seconds: age_seconds},
        running: [],
        retrying: [],
        idle: []
      },
      decisions: []
    }

    membership_fun = fn ->
      %{generation: 7, health: :healthy, freshness: %{status: :fresh}, members: [], truncated?: false}
    end

    activity_fun = fn -> %{generation: 8, health: :healthy, freshness: %{status: :fresh}, entries: []} end

    UnitsPresenter.load(payload, membership_fun: membership_fun, activity_fun: activity_fun).status
  end

  defp start_orchestrator do
    name = :"cadence_freshness_orchestrator_#{System.unique_integer([:positive])}"
    parent = self()

    pid =
      spawn(fn ->
        Process.register(self(), name)
        send(parent, :registered)

        receive do
          :never -> :ok
        end
      end)

    receive do
      :registered -> :ok
    after
      1_000 -> flunk("orchestrator stub never registered")
    end

    SnapshotStore.begin_generation(name)

    on_exit(fn ->
      SnapshotStore.discard(name)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    name
  end

  # `publish/2` stamps the current monotonic clock, so the only way to observe a
  # 1200s-old snapshot without waiting 1200s is to restate its observation time.
  defp publish_aged(orchestrator, age_ms) do
    :ok = SnapshotStore.publish(orchestrator, %{globally_paused: false})

    cached = :persistent_term.get({SnapshotStore, orchestrator})
    observed_at_ms = System.monotonic_time(:millisecond) - age_ms

    :persistent_term.put(
      {SnapshotStore, orchestrator},
      %{
        cached
        | observed_at_ms: observed_at_ms,
          observed_at: DateTime.add(DateTime.utc_now(), -age_ms, :millisecond),
          recent_gaps_ms: []
      }
    )

    :ok
  end

  defp backlog(orchestrator, count) do
    pid = Process.whereis(orchestrator)
    Enum.each(1..count, fn _ -> send(pid, :backlog) end)

    # The stub never receives, so the messages queue: assert the depth is really
    # there rather than trusting the send.
    assert {:message_queue_len, ^count} = Process.info(pid, :message_queue_len)
  end
end
