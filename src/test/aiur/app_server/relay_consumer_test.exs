defmodule Aiur.AppServer.RelayConsumerTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.{Interrupts, Rpc}
  alias Aiur.AppServer.Rpc.StreamDiagnostics
  alias Aiur.Codex.ExhaustedReset

  defmodule Backend do
    def send_frame(port, frame) do
      send(port, {:frame, frame})
      :ok
    end
  end

  test "diagnostics retain and clear lines for a relay process" do
    StreamDiagnostics.record(self(), "relay provider error")
    assert StreamDiagnostics.recent_text(self()) == "relay provider error"
    StreamDiagnostics.clear(self())
    assert StreamDiagnostics.recent_text(self()) == ""
  end

  test "late sensitive responses remain scoped to the relay process" do
    Rpc.retain_late_sensitive_response(self(), 17)
    assert Rpc.discard_late_sensitive_response?(self(), %{"id" => 17, "result" => %{"token" => "secret"}})
    refute Rpc.discard_late_sensitive_response?(self(), %{"id" => 17, "result" => %{}})
    Rpc.retain_late_sensitive_response(self(), 18, true)
    Rpc.clear_late_sensitive_responses(self())
    refute Rpc.discard_late_sensitive_response?(self(), "remaining partial")
  end

  test "interrupts accept relay process handles" do
    session = %{port: self(), thread_id: "thread"}
    assert {:ok, request_id} = Interrupts.interrupt_turn(Backend, session, "turn")
    assert_receive {:frame, %{"id" => ^request_id, "method" => "turn/interrupt", "params" => %{"threadId" => "thread", "turnId" => "turn"}}}, 1_000
  end

  test "exhausted rate limit resets are retained for relay processes" do
    now = ~U[2026-10-09 00:00:00Z]
    reset = DateTime.add(now, 120)
    session = %{port: self()}
    ExhaustedReset.observe(session, %{"primary" => %{"usedPercent" => 100, "resetsAt" => DateTime.to_unix(reset)}})
    assert ExhaustedReset.latest(session, now) == reset
    ExhaustedReset.clear(session)
    assert ExhaustedReset.latest(session, now) == nil
  end
end
