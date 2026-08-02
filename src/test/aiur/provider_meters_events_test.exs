defmodule Aiur.ProviderMeters.EventsTest do
  use ExUnit.Case, async: false

  alias Aiur.ProviderMeters.Events
  alias Aiur.ProviderMeterSnapshot

  setup do
    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
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

  test "a generation-scoped subscriber only sees its own generation" do
    :ok = Events.subscribe(:codex, :app_server, "gen-mine")

    :ok = Events.broadcast(snapshot("gen-theirs"))

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
end
