defmodule AiurWeb.StreamdeckVoiceLatencyTest do
  @moduledoc """
  Measures the dictation round trip against the live ElevenLabs API.

  Excluded from the default run: it needs `ELEVENLABS_API_KEY`, network access
  and a raw PCM fixture, so it is evidence gathered on demand rather than a
  gate. Run it with:

      AIUR_VOICE_FIXTURE=/path/to/speech.raw mix test --only external \\
        test/aiur_web/streamdeck_voice_latency_test.exs

  The fixture is 16 kHz mono s16le — exactly what `parec` produces on the
  sidecar — pushed in 3,200-byte frames at the 100 ms cadence `aggregate.ts`
  emits, so the timings are the ones an operator actually experiences.

  What it reports, and why each number is the one that matters:

    * **partial lag** — how far the text trails the speech that produced it,
      computed as elapsed wall time minus audio already streamed. Elapsed time
      alone would conflate the lag with the time spent speaking and make a
      perfect transcriber look slow.
    * **release to final** — the commit flush to the settled transcript. This is
      the pause the operator sees between letting go of the Mic key and the
      message being ready to send.

  This is deliberately *not* a timing assertion. It prints a measurement and
  asserts only that the transcription arrived and is right; a threshold here
  would be a network-speed test and would flake, which is the failure #1983
  fixed elsewhere.
  """

  use ExUnit.Case, async: false

  alias Aiur.ElevenLabs.Realtime

  @moduletag :external

  @frame_bytes 3_200
  @frame_ms 100

  test "the dictation round trip through Aiur's provider session" do
    fixture = System.get_env("AIUR_VOICE_FIXTURE") || flunk("set AIUR_VOICE_FIXTURE to a 16 kHz mono s16le file")
    pcm = File.read!(fixture)

    {:ok, session} =
      Realtime.start(
        owner: self(),
        api_key_fun: fn -> System.get_env("ELEVENLABS_API_KEY") end,
        language_code: "eng"
      )

    started_at = System.monotonic_time(:millisecond)

    {lags, audio_ms} = stream(session, chunk_frames(pcm), started_at, 0, [])

    released_at = System.monotonic_time(:millisecond)
    Realtime.commit(session)

    {final_text, lags} = await_final(started_at, audio_ms, lags)
    release_to_final_ms = System.monotonic_time(:millisecond) - released_at

    lag_values = lags |> Enum.reverse() |> Enum.map(&elem(&1, 0))

    IO.puts("""

    Stream Deck dictation round trip, through Aiur, against live ElevenLabs
      audio streamed            #{audio_ms} ms in #{div(byte_size(pcm), @frame_bytes)} frames of #{@frame_bytes} B
      partial updates           #{length(lag_values)}
      partial lag (ms)          min #{Enum.min(lag_values, fn -> 0 end)} / median #{median(lag_values)} / max #{Enum.max(lag_values, fn -> 0 end)}
      release -> final (ms)     #{release_to_final_ms}
      transcript                #{inspect(final_text)}
    """)

    assert final_text =~ "country"
    assert lag_values != [], "no partial transcripts arrived; the live readout would be blank"
  end

  defp chunk_frames(pcm) do
    pcm |> :binary.bin_to_list() |> Enum.chunk_every(@frame_bytes) |> Enum.map(&:binary.list_to_bin/1)
  end

  # Lag is measured against audio already sent, not against zero: at a 1x
  # cadence a transcriber that is exactly keeping up reads as ~0 ms here, which
  # is the property the live readout depends on.
  # Paces frames against an absolute deadline and blocks in `receive` between
  # them, rather than sleeping and draining afterwards. Both details are the
  # measurement:
  #
  #   * a flat `Process.sleep(100)` per frame overshoots a little every time, and
  #     over a hundred frames the drift accumulates into the result — it showed
  #     up as ~120 ms of phantom lag;
  #   * draining the mailbox only at frame boundaries timestamps every partial at
  #     the boundary instead of at arrival, which quantises the answer to the
  #     frame period and reports a uniform ~1 ms however slow the provider is.
  defp stream(_session, [], started_at, sent_ms, lags), do: {settle(started_at, sent_ms, lags), sent_ms}

  defp stream(session, [frame | rest], started_at, sent_ms, lags) do
    # Wait for the frame's audio to *exist* before pushing it. A live microphone
    # cannot hand over the 100 ms ending at T until T; replaying a file pushes
    # frame N as fast as the loop comes round, which is 100 ms ahead of live and
    # made every measured lag read a full frame too early — negative, in fact.
    sent_ms = sent_ms + @frame_ms
    lags = await_until(started_at + sent_ms, started_at, sent_ms - @frame_ms, lags)
    Realtime.push(session, Base.encode64(frame))
    stream(session, rest, started_at, sent_ms, lags)
  end

  defp await_until(deadline, started_at, sent_ms, lags) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      lags
    else
      receive do
        {:elevenlabs_transcript, :partial, text} ->
          await_until(deadline, started_at, sent_ms, [{lag(started_at, sent_ms), text} | lags])
      after
        remaining -> lags
      end
    end
  end

  defp settle(started_at, sent_ms, lags), do: await_until(System.monotonic_time(:millisecond), started_at, sent_ms, lags)

  defp lag(started_at, sent_ms), do: System.monotonic_time(:millisecond) - started_at - sent_ms

  defp await_final(started_at, sent_ms, lags) do
    receive do
      {:elevenlabs_transcript, :final, text} -> {text, lags}
      {:elevenlabs_transcript, :partial, text} -> await_final(started_at, sent_ms, [{lag(started_at, sent_ms), text} | lags])
      {:elevenlabs_error, reason} -> flunk("provider failed: #{reason}")
    after
      15_000 -> flunk("no settled transcript within 15s")
    end
  end

  defp median([]), do: 0

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end
end
