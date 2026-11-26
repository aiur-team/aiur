defmodule AiurWeb.ExecutorVoiceChannelTest do
  use ExUnit.Case, async: true

  alias AiurWeb.ExecutorVoiceChannel, as: Channel
  alias Phoenix.Socket.Message

  defmodule Serializer do
    def encode!(message), do: message
  end

  defp socket do
    %Phoenix.Socket{topic: "voice:executor", joined: true, transport_pid: self(), serializer: Serializer, assigns: %{session: self(), bytes: 0}}
  end

  test "Executor topic requires authenticated dashboard authority" do
    assert {:error, %{reason_code: "auth_changed"}} = Channel.join("voice:executor", %{}, socket())
  end

  test "oversized and malformed PCM are rejected without forwarding audio" do
    for data <- [String.duplicate("A", 350_000), "invalid!", Base.encode64(<<1>>)] do
      assert {:noreply, _} = Channel.handle_in("audio", %{"data" => data}, socket())
      assert_received %Message{event: "error", payload: %{reason: reason}}
      assert reason =~ "audio"
      refute_received {:"$gen_cast", {:audio, _}}
    end
  end

  test "normalized reply audio and interruptions reach the dedicated browser transport" do
    audio = %{__struct__: VoiceConverse.Events.AgentAudio, data_b64: "AAAA", format: :pcm_16000, turn_id: "turn"}
    assert {:noreply, _} = Channel.handle_info({:executor_voice, audio}, socket())
    assert_received %Message{topic: "voice:executor", event: "audio", payload: %{data: "AAAA", format: :pcm_16000}}
    interruption = %{__struct__: VoiceConverse.Events.Interruption, turn_id: "turn"}
    assert {:noreply, _} = Channel.handle_info({:executor_voice, interruption}, socket())
    assert_received %Message{event: "interruption"}
  end

  test "provider close waits for a handoff receipt before the session end signal" do
    closed = %{__struct__: VoiceConverse.Events.Closed, reason: :user_end}
    assert {:noreply, _} = Channel.handle_info({:executor_voice, closed}, socket())
    refute_received %Message{event: "ended"}
    receipt = %{id: 15, at: "2026-10-27T10:00:00Z", status: "queued"}
    assert {:noreply, _} = Channel.handle_info({:executor_voice, {:receipt, receipt}}, socket())
    assert_received %Message{event: "receipt", payload: ^receipt}
    assert {:noreply, _} = Channel.handle_info({:executor_voice, {:ended, :user_end}}, socket())
    assert_received %Message{event: "ended"}
  end

  test "authentication generation changes terminate Executor voice" do
    current = %{socket() | assigns: %{generation: "current"}}
    assert {:noreply, ^current} = Channel.handle_info({AiurWeb.FinancialDataAccess, :configuration_changed, "current"}, current)
    assert {:stop, :normal, ^current} = Channel.handle_info({AiurWeb.FinancialDataAccess, :configuration_changed, "new"}, current)
  end
end
