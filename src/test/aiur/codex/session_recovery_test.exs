defmodule Aiur.Codex.SessionRecoveryTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.SessionRecovery

  @active_turn_mismatch %{
    "code" => -32600,
    "message" => "expected active turn id 019f7020-f11c-73d3-b590-c91d83636ae3 but found 019f7020-eb13-7590-b948-707ab116e522"
  }

  test "classifies direct and wrapped Codex transport losses as recoverable" do
    assert SessionRecovery.recoverable?(:port_closed)
    assert SessionRecovery.recoverable?({:port_exit, 9})
    assert SessionRecovery.recoverable?({:turn_start_failed, :port_closed})
    assert SessionRecovery.recoverable?({:turn_interrupt_failed, {:port_exit, 9}})
    assert SessionRecovery.recoverable?({:turn_start_failed, {:turn_interrupt_failed, :port_closed}})
  end

  test "classifies only an exact active-turn mismatch as recoverable" do
    assert SessionRecovery.recoverable?({:turn_interrupt_failed, @active_turn_mismatch})

    refute SessionRecovery.recoverable?(
             {:turn_interrupt_failed,
              %{
                "code" => -32600,
                "message" => "expected active turn id turn-1 but found turn-1"
              }}
           )

    refute SessionRecovery.recoverable?(
             {:turn_interrupt_failed,
              %{
                "code" => -32600,
                "message" => "expected active turn id turn-1 but found turn-2."
              }}
           )

    refute SessionRecovery.recoverable?(
             {:turn_interrupt_failed,
              %{
                "code" => -32600,
                "message" => "no active turn to interrupt"
              }}
           )
  end

  test "keeps genuine provider failures on the hard-failure path" do
    refute SessionRecovery.recoverable?({:turn_start_failed, :provider_rejected})
    refute SessionRecovery.recoverable?({:turn_start_failed, :response_timeout})
    refute SessionRecovery.recoverable?({:turn_interrupt_failed, :invalid_session})
    refute SessionRecovery.recoverable?(%{"code" => -32600, "message" => "unwrapped mismatch"})
  end
end
