defmodule Aiur.VoiceConverse.Host.TelemetryTest do
  use ExUnit.Case, async: false

  alias Aiur.VoiceConverse.Host.Telemetry

  test "cleanup give-up emits one attention alert" do
    owner = self()
    handler = {__MODULE__, make_ref()}
    assert :ok = Telemetry.attach(handler, fn name, message, opts -> send(owner, {:alert, name, message, opts}) end)
    on_exit(fn -> :telemetry.detach(handler) end)

    :telemetry.execute([:voice_converse, :provider_cleanup, :give_up], %{count: 1}, %{})

    assert_receive {:alert, "voice_conversation.provider_cleanup.give_up", _, [needs_attention: true]}, 1_000
    refute_receive {:alert, _, _, _}, 50
  end

  test "reaching the daily cap emits an attention alert" do
    owner = self()
    handler = {__MODULE__, make_ref()}
    assert :ok = Telemetry.attach(handler, fn name, message, opts -> send(owner, {:alert, name, message, opts}) end)
    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, :cost_cap} = VoiceConverse.SessionLimits.under_daily_cap?(%VoiceConverse.Config{limits: %{daily_minutes_cap: 0}})
    assert_receive {:alert, "voice_conversation.cost_cap.reached", _, [needs_attention: true]}, 1_000
  end
end
