defmodule Aiur.ProviderMeters.EventsTest do
  use ExUnit.Case, async: false

  alias Aiur.ProviderMeters.Events
  alias Aiur.ProviderMeterSnapshot

  setup do
    ensure_pubsub!()
    :ok
  end

  test "coverage-4 fixtures never create a test-owned Aiur PubSub" do
    # These fixtures run beside ApplicationTest in coverage shard 4. The
    # application owns Aiur.PubSub through Aiur.PubSub.Boot; an ExUnit-owned
    # Phoenix.PubSub vanishes with its case and leaves the shared tree's child
    # state inconsistent for a later supervision-contract test.
    for path <- [
          __ENV__.file,
          Path.expand("build_order/ad_hoc_source_test.exs", __DIR__),
          Path.expand("../aiur_web/voice_channel_test.exs", __DIR__)
        ] do
      refute File.read!(path) =~ ~r/start_supervised!\(\{Phoenix\.PubSub, name: Aiur\.PubSub\}\)/
    end
  end

  test "an observation reaches both the generation-scoped and the fan-out topic" do
    :ok = Events.subscribe(:codex, :app_server, "gen-1")
    :ok = Events.subscribe_observed()

    snapshot = snapshot("gen-1")
    :ok = Events.broadcast(snapshot)

    # Both subscriptions are held by this process, so a correct broadcast
    # delivers exactly twice — once per topic.
    assert_receive {:provider_meter_changed, ^snapshot}
    assert_receive {:provider_meter_changed, ^snapshot}
    refute_receive {:provider_meter_changed, _other}, 50
  end

  # The point of the fan-out topic: a listener that holds no binding, and so
  # cannot name the generation-scoped topic, still sees every observation.
  test "the fan-out topic delivers regardless of account generation" do
    :ok = Events.subscribe_observed()

    :ok = Events.broadcast(snapshot("gen-a"))
    :ok = Events.broadcast(snapshot("gen-b"))

    assert_receive {:provider_meter_changed, %{provider_account_generation: "gen-a"}}
    assert_receive {:provider_meter_changed, %{provider_account_generation: "gen-b"}}
  end

  test "an account-wide observation without a generation only reaches fan-out" do
    :ok = Events.subscribe_observed()
    :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, "provider_meters:codex:app_server:")

    snapshot = snapshot(nil)
    :ok = Events.broadcast(snapshot)

    assert_receive {:provider_meter_changed, ^snapshot}
    refute_received {:provider_meter_changed, ^snapshot}
  end

  test "a generation-scoped subscriber only sees its own generation" do
    :ok = Events.subscribe(:codex, :app_server, "gen-mine")

    :ok = Events.broadcast(snapshot("gen-theirs"))

    refute_receive {:provider_meter_changed, _snapshot}, 50
  end

  test "broadcast_from excludes the publishing projection from both topics" do
    :ok = Events.subscribe(:codex, :app_server, "gen-1")
    :ok = Events.subscribe_observed()

    :ok = Events.broadcast_from(self(), snapshot("gen-1"))

    refute_receive {:provider_meter_changed, _snapshot}, 50
  end

  test "topics are distinct and stable" do
    assert Events.topic(:codex, :app_server, "gen-1") == "provider_meters:codex:app_server:gen-1"
    assert Events.fanout_topic() == "provider_meters:observed"
    refute Events.fanout_topic() == Events.topic(:codex, :app_server, "gen-1")
  end

  defp snapshot(generation) do
    %ProviderMeterSnapshot{
      provider: :codex,
      backend: :app_server,
      provider_account_generation: generation,
      observed_at: ~U[2026-07-27 12:00:00Z],
      windows: %{}
    }
  end

  defp ensure_pubsub! do
    assert :ok = Aiur.TestSupport.ensure_pubsub_running()
  end
end
