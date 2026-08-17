defmodule Aiur.ElevenLabs.TTSTest do
  use ExUnit.Case, async: true

  alias Aiur.ElevenLabs.TTS

  @api_key "sk-secret-tts-key"
  @voice_id "voice/with spaces"

  test "streams PCM chunks while keeping the credential out of the URL" do
    owner = self()

    request = fn url, options ->
      send(owner, {:request, url, options})
      into = Keyword.fetch!(options, :into)
      request = Req.new()
      response = %Req.Response{status: 200}
      assert {:cont, {_request, _response}} = into.({:data, <<1, 2>>}, {request, response})
      assert {:cont, {_request, _response}} = into.({:data, <<3, 4>>}, {request, response})
      {:ok, response}
    end

    assert {:ok, pid} =
             TTS.start(self(), " Agent reply ",
               api_key_fun: fn -> @api_key end,
               voice_id_fun: fn -> @voice_id end,
               request_fun: request
             )

    monitor = Process.monitor(pid)
    assert_receive {:request, url, options}
    refute url =~ @api_key
    assert url =~ URI.encode(@voice_id, &URI.char_unreserved?/1)
    assert {"xi-api-key", @api_key} in Keyword.fetch!(options, :headers)
    assert Keyword.fetch!(options, :json) == %{text: "Agent reply", model_id: "eleven_flash_v2_5"}
    assert_receive {:elevenlabs_audio, :chunk, <<1, 2>>}
    assert_receive {:elevenlabs_audio, :chunk, <<3, 4>>}
    assert_receive {:elevenlabs_audio, :done}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "refuses missing configuration and invalid text before making a request" do
    request = fn _url, _options -> flunk("request should not run") end

    assert {:error, :unconfigured} =
             TTS.start(self(), "hello", api_key_fun: fn -> nil end, voice_id_fun: fn -> "voice" end, request_fun: request)

    assert {:error, :unconfigured} =
             TTS.start(self(), "hello", api_key_fun: fn -> @api_key end, voice_id_fun: fn -> nil end, request_fun: request)

    assert {:error, :empty_text} =
             TTS.start(self(), "   ", api_key_fun: fn -> @api_key end, voice_id_fun: fn -> "voice" end, request_fun: request)

    assert {:error, :text_too_large} =
             TTS.start(self(), String.duplicate("x", 16_001),
               api_key_fun: fn -> @api_key end,
               voice_id_fun: fn -> "voice" end,
               request_fun: request
             )
  end

  test "accepts the text boundary and stops an oversized audio stream" do
    owner = self()

    request = fn _url, options ->
      into = Keyword.fetch!(options, :into)
      request = Req.new()
      response = %Req.Response{status: 200}
      assert {:halt, {_request, _response}} = into.({:data, <<1, 2, 3, 4>>}, {request, response})
      {:ok, response}
    end

    assert {:ok, pid} =
             TTS.start(self(), String.duplicate("x", 16_000),
               api_key_fun: fn -> @api_key end,
               voice_id_fun: fn -> "voice" end,
               request_fun: request,
               max_audio_bytes: 3
             )

    monitor = Process.monitor(pid)
    assert_receive {:elevenlabs_audio, :error, "Voice reply exceeded its playback limit"}
    refute_receive {:elevenlabs_audio, :chunk, _data}
    refute_receive {:elevenlabs_audio, :done}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert Process.alive?(owner)
  end

  test "turns provider and transport failures into non-secret operator messages" do
    for result <- [{:ok, %Req.Response{status: 403}}, {:error, %{request_headers: [{"xi-api-key", @api_key}]}}] do
      assert {:ok, pid} =
               TTS.start(self(), "hello",
                 api_key_fun: fn -> @api_key end,
                 voice_id_fun: fn -> "voice" end,
                 request_fun: fn _url, _options -> result end
               )

      monitor = Process.monitor(pid)
      assert_receive {:elevenlabs_audio, :error, reason}
      refute reason =~ @api_key
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    end
  end
end
