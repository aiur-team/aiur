defmodule VoiceConverse.Provider.ElevenLabsNarrationTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.{Events, Narration}
  alias VoiceConverse.Provider.ElevenLabsAgents
  alias VoiceConverse.Testing.StaticCredentials

  @voice "voice-test"

  setup do
    StaticCredentials.put(%{elevenlabs: "xi-test-secret"}, observer: self())
    on_exit(fn -> StaticCredentials.put(%{}) end)
    :ok
  end

  test "Narration renders timestamped PCM using displayed character alignment" do
    {:ok, result} = Narration.render("Hi!", narration_opts(http: response(200, documented_body())))

    assert result.audio == <<1, 0, 2, 0>>
    assert result.format == :pcm_24000
    assert Enum.map(result.alignment, & &1.text) == ["H", "i", "!"]
    assert Enum.map(result.alignment, & &1.start_ms) == [0, 40, 80]
    assert_received {StaticCredentials, :fetch, :elevenlabs, :render}
  end

  test "missing credential returns provider_auth without an HTTP request" do
    StaticCredentials.put(%{})

    assert {:error, %Events.Error{code: :provider_auth, message: "no credential for elevenlabs"}} =
             ElevenLabsAgents.render_speech(spec(http: fn _, _ -> flunk("request should not run") end))
  end

  test "HTTP failures map to a safe provider error" do
    assert {:error, %Events.Error{code: :provider_quota, message: "ElevenLabs quota is unavailable."}} =
             ElevenLabsAgents.render_speech(spec(http: response(429, "private provider response")))
  end

  test "malformed displayed alignment is rejected" do
    malformed =
      Jason.decode!(documented_body())
      |> put_in(["alignment", "character_end_times_seconds"], [0.02])
      |> Jason.encode!()

    assert {:error, %Events.Error{code: :provider_error}} =
             ElevenLabsAgents.render_speech(spec(http: response(200, malformed)))
  end

  test "request uses ElevenLabs timestamped TTS endpoint and credential header" do
    http = fn url, opts ->
      send(self(), {:request, url, opts})
      {:ok, 200, documented_body()}
    end

    assert {:ok, _} = ElevenLabsAgents.render_speech(spec(http: http))
    assert_received {:request, url, opts}
    assert url =~ "/v1/text-to-speech/#{@voice}/with-timestamps?"
    assert url =~ "output_format=pcm_24000"
    assert {"xi-api-key", "xi-test-secret"} in opts[:headers]
    assert Jason.decode!(opts[:body]) == %{"text" => "Hi!"}
  end

  defp narration_opts(extra),
    do:
      [provider: ElevenLabsAgents, privacy: %{}, credentials: {StaticCredentials, :elevenlabs}, voice_id: @voice] ++
        extra

  defp spec(extra),
    do:
      Map.merge(
        %{text: "Hi!", format: :pcm_24000, voice_id: @voice, credentials: {StaticCredentials, :elevenlabs}},
        Map.new(extra)
      )

  defp response(status, body), do: fn _url, _opts -> {:ok, status, body} end

  defp documented_body do
    Jason.encode!(%{
      audio_base64: Base.encode64(<<1, 0, 2, 0>>),
      alignment: %{
        characters: ["H", "i", "!"],
        character_start_times_seconds: [0.0, 0.04, 0.08],
        character_end_times_seconds: [0.04, 0.08, 0.12]
      },
      normalized_alignment: %{
        characters: ["H", "i"],
        character_start_times_seconds: [0.0, 0.04],
        character_end_times_seconds: [0.04, 0.08]
      }
    })
  end
end
