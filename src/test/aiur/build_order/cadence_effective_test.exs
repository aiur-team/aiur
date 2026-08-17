defmodule Aiur.BuildOrder.CadenceEffectiveTest do
  # `async: false`: `PollCadence` publishes the effective interval into
  # `:persistent_term`, which is process-global.
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.Cadence
  alias Aiur.Config.Schema
  alias Aiur.PollCadence

  # One hour, in milliseconds. Every count below is stated as absolute requests
  # per hour, which is the only unit #2118 accepts.
  @hour_ms 3_600_000

  # The shipped defaults, spelled out so the arithmetic is checkable:
  # polling.interval_seconds 120, polling.idle_widen_factor 5.0.
  @base_interval_ms 120_000
  @idle_interval_ms 600_000

  setup do
    previous = :persistent_term.get({Aiur.PollCadence, :effective_interval_ms}, :unset)

    on_exit(fn ->
      case previous do
        :unset -> PollCadence.forget_effective_interval_ms()
        value -> PollCadence.publish_effective_interval_ms(value)
      end
    end)

    PollCadence.forget_effective_interval_ms()
    :ok
  end

  # Measured with GitHub's own `rateLimit { cost }` (#1766): the cheap catalog
  # read is 1 point a page, the variant that resolves per-member labels is 26.
  @cheap_catalog_points 1
  @labelled_catalog_points 26

  defp requests_per_hour(interval_ms), do: div(@hour_ms, interval_ms)

  # Every catalog sweep is one request; one in every
  # `graph_catalog_labels_refresh_ms` of them buys the expensive variant instead
  # of the cheap one.
  defp points_per_hour(cadence) do
    sweeps = requests_per_hour(cadence.graph_catalog_refresh_ms)
    labelled = requests_per_hour(cadence.graph_catalog_labels_refresh_ms)

    (sweeps - labelled) * @cheap_catalog_points + labelled * @labelled_catalog_points
  end

  describe "the catalog cadence at idle" do
    # The defect, stated as a number. The catalog is a daemon-owned
    # reconciliation that runs for nobody; before this it fired at the *base*
    # interval while the tracker it projects had already widened to 600s, so it
    # polled five times more often than the thing it mirrors.
    test "an idle hour costs 6 catalog requests, not 30" do
      PollCadence.publish_effective_interval_ms(@idle_interval_ms)

      assert Cadence.effective().graph_catalog_refresh_ms == @idle_interval_ms
      assert requests_per_hour(Cadence.effective().graph_catalog_refresh_ms) == 6

      # What the base interval used to buy, for comparison.
      assert requests_per_hour(Cadence.derive(120).graph_catalog_refresh_ms) == 30
    end

    # The labelled variant resolves per-member labels and costs 26 points a page
    # against the cheap read's 1 (#1766), so its own hourly count is what
    # dominates the points bill.
    test "an idle hour costs at most 2 labelled catalog requests" do
      PollCadence.publish_effective_interval_ms(@idle_interval_ms)

      labels_ms = Cadence.effective().graph_catalog_labels_refresh_ms

      assert labels_ms == 3_000_000
      assert requests_per_hour(labels_ms) <= 2
    end

    # An hour of the shipped idle cadence, priced with the per-request costs from
    # #1766: 1 point for the cheap catalog read, 26 for the labelled one.
    test "the idle points bill drops from about 180 an hour to about 31" do
      before_cadence = Cadence.derive(120)

      assert points_per_hour(before_cadence) == 180

      PollCadence.publish_effective_interval_ms(@idle_interval_ms)

      assert points_per_hour(Cadence.effective()) == 31
    end

    # It has to come back on its own, or the saving is bought with a fleet that
    # never notices work arriving.
    test "a busy fleet narrows the catalog straight back to the tracker's cadence" do
      PollCadence.publish_effective_interval_ms(@idle_interval_ms)
      assert Cadence.effective().graph_catalog_refresh_ms == @idle_interval_ms

      PollCadence.publish_effective_interval_ms(@base_interval_ms)
      assert Cadence.effective().graph_catalog_refresh_ms == @base_interval_ms
      assert requests_per_hour(Cadence.effective().graph_catalog_refresh_ms) == 30
    end

    # Cold start: before the dispatcher has ever scheduled a tick, `PollCadence`
    # answers with the widest cadence the configuration permits. That is
    # deliberately never tighter than the base, so booting cannot cost more than
    # it did.
    test "before the dispatcher has published anything the cadence is never tighter than the base" do
      PollCadence.forget_effective_interval_ms()

      base = Cadence.derive_ms(PollCadence.base_interval_ms())

      assert Cadence.effective().graph_catalog_refresh_ms >= base.graph_catalog_refresh_ms
    end
  end

  # A derived number that never reaches the projection's policy is a comment.
  describe "the wiring from the dispatcher's schedule to the projection's options" do
    test "the projection's catalog option follows the published effective interval" do
      PollCadence.publish_effective_interval_ms(@idle_interval_ms)

      idle_options = Aiur.Config.build_order_graph_projection_options()
      assert idle_options[:catalog_refresh_ms] == @idle_interval_ms

      PollCadence.publish_effective_interval_ms(@base_interval_ms)

      busy_options = Aiur.Config.build_order_graph_projection_options()
      assert busy_options[:catalog_refresh_ms] == @base_interval_ms
    end

    test "the ticket-detail freshness window follows it too" do
      PollCadence.publish_effective_interval_ms(@idle_interval_ms)

      idle = Aiur.Config.build_order_ticket_detail_coordinator_options()[:freshness_ms]

      PollCadence.publish_effective_interval_ms(@base_interval_ms)

      busy = Aiur.Config.build_order_ticket_detail_coordinator_options()[:freshness_ms]

      assert idle > busy
    end
  end

  describe "derivation stays inside the schema's own rules" do
    test "every effective interval derives values the schema would accept" do
      for interval_ms <- [1_000, 120_000, 600_000, 1_200_000, 3_600_000, 86_400_000] do
        PollCadence.publish_effective_interval_ms(interval_ms)
        derived = Cadence.effective()

        assert derived.graph_catalog_labels_refresh_ms >= derived.graph_catalog_refresh_ms

        assert {:ok, _settings} =
                 Schema.parse(%{
                   "build_order" => %{
                     "graph_catalog_refresh_ms" => derived.graph_catalog_refresh_ms,
                     "graph_catalog_labels_refresh_ms" => derived.graph_catalog_labels_refresh_ms,
                     "ticket_detail_freshness_ms" => derived.ticket_detail_freshness_ms
                   }
                 })
      end
    end

    test "derive_ms/1 degrades on nonsense rather than raising" do
      for interval <- [0, -1, nil, "600000", :bad] do
        assert %{graph_catalog_refresh_ms: ms} = Cadence.derive_ms(interval)
        assert is_integer(ms) and ms > 0
      end
    end
  end

  # The reference's idle column has to agree with what the code does, or an
  # operator reads a number that is not the one being spent.
  describe "the configuration reference's idle column" do
    @doc_path Path.expand("../../../../website/docs-app/reference/configuration.md", __DIR__)

    test "documents the values derived at a 600s effective interval" do
      reference = File.read!(@doc_path)
      PollCadence.publish_effective_interval_ms(@idle_interval_ms)
      derived = Cadence.effective()

      for {key, field} <- [
            {"graph_catalog_refresh_ms", :graph_catalog_refresh_ms},
            {"graph_catalog_labels_refresh_ms", :graph_catalog_labels_refresh_ms},
            {"ticket_detail_freshness_ms", :ticket_detail_freshness_ms}
          ] do
        assert documented_idle(reference, key) == Map.fetch!(derived, field)
      end
    end

    defp documented_idle(reference, key) do
      regex = ~r/^\| `#{Regex.escape(key)}` \| [^|]+ \| \d+ \| (?<value>\d+) \|/m

      case Regex.scan(regex, reference, capture: :all_names) do
        [[value]] -> String.to_integer(value)
        other -> flunk("the reference documents #{length(other)} idle values for #{key}")
      end
    end
  end

  describe "resolve_effective/3" do
    test "an explicit setting always beats the derivation" do
      PollCadence.publish_effective_interval_ms(@idle_interval_ms)

      assert Cadence.resolve_effective(:graph_catalog_refresh_ms, 7_000) == 7_000
    end

    test "an unset setting follows the effective interval, not the configured one" do
      PollCadence.publish_effective_interval_ms(@idle_interval_ms)

      assert Cadence.resolve_effective(:graph_catalog_refresh_ms, nil) == @idle_interval_ms
      refute Cadence.resolve_effective(:graph_catalog_refresh_ms, nil) == @base_interval_ms
    end

    test "a nonpositive setting is treated as unset" do
      PollCadence.publish_effective_interval_ms(@idle_interval_ms)

      assert Cadence.resolve_effective(:graph_catalog_refresh_ms, 0) == @idle_interval_ms
      assert Cadence.resolve_effective(:graph_catalog_refresh_ms, -5) == @idle_interval_ms
    end
  end
end
