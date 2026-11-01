defmodule VoiceConverse.TextTimingWireTest do
  use ExUnit.Case, async: true
  alias VoiceConverse.{Events, Wire}
  alias VoiceConverse.Transport.WebSock.Socket

  test "timing and old and extended playback frames round trip through codec and public schema" do
    frames = [
      %{
        "v" => 1,
        "type" => "agent_text_timing",
        "turn_id" => "t",
        "text" => "é👋",
        "chars" => [%{"offset_ms" => 0, "length" => 1}, %{"offset_ms" => 30, "length" => 1}],
        "audio_offset_ms" => 0,
        "estimated" => false
      },
      %{
        "v" => 1,
        "type" => "agent_text_timing",
        "turn_id" => "t",
        "text" => "x",
        "audio_offset_ms" => 0,
        "estimated" => true
      },
      %{"v" => 1, "type" => "playback_state", "state" => "stopped"},
      %{"v" => 1, "type" => "playback_state", "state" => "stopped", "turn_id" => "t", "played_until_ms" => 0}
    ]

    validator = Path.expand("../../../../aiur-contracts/scripts/validate-voice-converse-frame.mjs", __DIR__)

    for frame <- frames do
      assert {:ok, json} = Wire.encode(frame)
      assert {:ok, ^frame} = Wire.decode(json)
      assert {_, 0} = System.cmd("node", [validator, json], stderr_to_stdout: true)
    end
  end

  test "malformed playback offsets and timing spans are refused" do
    for value <- [-1, 1.5, "20", nil] do
      assert {:error, :invalid_frame} =
               Wire.encode(%{v: 1, type: "playback_state", state: "stopped", turn_id: "t", played_until_ms: value})
    end

    assert {:error, :invalid_frame} =
             Wire.encode(%{
               v: 1,
               type: "agent_text_timing",
               turn_id: "t",
               text: "x",
               audio_offset_ms: 0,
               estimated: true,
               chars: [%{offset_ms: -1, length: 1}]
             })
  end

  test "socket broadcasts normalized timing and routes playback into the live session API" do
    parent = self()

    state =
      VoiceConverse.Transport.WebSock.socket_state(
        [
          api: %{
            playback_state: fn _, id, frame ->
              send(parent, {:report, id, frame})
              :ok
            end
          }
        ],
        true
      )
      |> Map.put(:conversation_id, "c")

    event = Events.AgentTextTiming.from_text_deltas("é", turn_id: "t", duration_ms: 100)
    assert {:push, {:text, json}, ^state} = Socket.handle_info({:voice_conversation, "c", event}, state)
    assert {:ok, %{"type" => "agent_text_timing", "chars" => [%{"offset_ms" => 0, "length" => 1}]}} = Wire.decode(json)
    report = %{"v" => 1, "type" => "playback_state", "state" => "stopped", "turn_id" => "t", "played_until_ms" => 5}
    assert {:ok, ^state} = Socket.handle_in({Jason.encode!(report), :text}, state)
    assert_receive {:report, "c", ^report}
  end
end
