defmodule VoiceConverse.Events.AgentTextTimingTest do
  use ExUnit.Case, async: true
  alias VoiceConverse.Events.AgentTextTiming, as: Timing

  test "all helpers preserve grapheme length and monotonic turn-relative offsets for randomized Unicode chunks" do
    :rand.seed(:exsss, {4105, 12, 1})

    for _ <- 1..200 do
      graphemes = for _ <- 1..:rand.uniform(30), do: Enum.random(["a", " ", "é", "é", "👩🏽‍💻", "🇫🇷"])
      text = Enum.join(graphemes)
      starts = Enum.map(graphemes, fn _ -> :rand.uniform(100) / 10 end)
      offset = :rand.uniform(10_000)
      opts = [turn_id: "t", audio_offset_ms: offset, duration_ms: 1_000]
      alignment = %{"characters" => graphemes, "character_start_times_seconds" => starts}
      words = Enum.zip_with(graphemes, starts, &%{text: &1, start_ms: round(&2 * 1_000)})

      for event <- [
            Timing.from_char_alignment(text, alignment, opts),
            Timing.from_word_timestamps(text, Keyword.put(opts, :words, words)),
            Timing.from_text_deltas(text, opts)
          ] do
        assert event.text == text
        assert Enum.sum_by(event.chars, &elem(&1, 1)) == length(graphemes)
        offsets = Enum.map(event.chars, &elem(&1, 0))
        assert offsets == Enum.sort(offsets)
        assert hd(offsets) >= offset
      end
    end
  end

  test "alignment uses graphemes even when provider splits codepoints and chunks restart at zero" do
    event =
      Timing.from_char_alignment(
        "é👩🏽‍💻",
        %{
          "characters" => ["e", "́", "👩", "🏽", "‍", "💻"],
          "character_start_times_seconds" => [0, 0.1, 0.2, 0.3, 0.4, 0.5]
        },
        turn_id: "t",
        audio_offset_ms: 700
      )

    assert event.chars == [{700, 1}, {900, 1}]
    refute event.estimated
    assert Timing.heard_prefix(event.text, event.chars, 901) == "é👩🏽‍💻"
    assert Timing.heard_prefix(event.text, event.chars, 900) == "é"
  end

  test "mismatch estimates from matching chunk duration and no audio yields nil" do
    event = Timing.from_char_alignment("🇫🇷ab", %{}, turn_id: 1, audio_offset_ms: 500, duration_ms: 300)
    assert event.estimated
    assert event.chars == [{500, 1}, {600, 1}, {700, 1}]
    assert Timing.from_text_deltas("x", turn_id: 1).chars == nil
    assert Timing.from_word_timestamps("a b", turn_id: 1, words: [%{text: "ab", start_ms: 0}]).estimated
  end

  test "estimates matching PCM and G.711 chunks from their audio format" do
    for {format, bytes} <- [
          {:pcm_16000, 32_000},
          {:pcm_24000, 48_000},
          {:pcm_44100, 88_200},
          {:g711_ulaw, 8_000},
          {:g711_alaw, 8_000}
        ] do
      audio = %{format: format, data_b64: Base.encode64(:binary.copy(<<0>>, bytes))}
      assert Timing.from_text_deltas("ab", turn_id: 1, audio: [audio]).chars == [{0, 1}, {500, 1}]
    end
  end
end
