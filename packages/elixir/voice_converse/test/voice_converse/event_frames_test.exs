defmodule VoiceConverse.EventFramesTest do
  use ExUnit.Case, async: true
  alias VoiceConverse.{EventFrames, Events, Wire}

  test "relay events match the shared golden wire frames" do
    golden = Path.expand("../fixtures/wire/v1.jsonl", __DIR__) |> File.stream!() |> Enum.map(&String.trim/1)

    events = [
      {:state, :listening},
      %Events.UserTranscript{text: "hello", final?: true},
      %Events.AgentText{turn_id: "turn-1", text: "hi", final?: true},
      %Events.AgentAudio{turn_id: "turn-1", format: :pcm_16000, data_b64: "AA=="},
      %Events.Interruption{turn_id: "turn-1"},
      {:error, :provider_error, "Provider error."},
      {:ended, :user_end}
    ]

    for event <- events do
      [frame] = EventFrames.frames(event)
      assert {:ok, json} = Wire.encode(frame)
      assert json in golden
      assert {:ok, decoded} = Wire.decode(json)
      assert decoded["type"] == frame.type
    end
  end

  test "malformed provider audio produces a typed error instead of crashing the relay" do
    assert [%{type: "error", code: "provider_error", message: "Invalid provider audio."}] =
             EventFrames.frames(%Events.AgentAudio{turn_id: "x", format: :pcm_16000, data_b64: "invalid!"})
  end
end
