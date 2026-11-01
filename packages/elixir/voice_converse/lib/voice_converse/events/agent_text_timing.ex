defmodule VoiceConverse.Events.AgentTextTiming do
  @moduledoc """
  Chunk text with grapheme spans starting at turn-relative audio milliseconds.

  Helpers take `turn_id`, `audio_offset_ms` (default 0) and `duration_ms` (default 0)
  in keyword options. `audio: [AgentAudio]` derives duration from matching PCM or G.711 chunks. `from_char_alignment/3` accepts ElevenLabs `characters` and
  `character_start_times_seconds` arrays for the displayed (not normalized) text.
  `from_word_timestamps/2` takes `words: [%{text: ..., start_ms: ...}]`; words must
  concatenate to the displayed text, including spaces. Mismatches fall back to estimation.
  """
  @enforce_keys [:turn_id, :text, :audio_offset_ms, :estimated]
  defstruct [:turn_id, :text, :chars, :audio_offset_ms, :estimated]

  @type t :: %__MODULE__{
          turn_id: term(),
          text: String.t(),
          chars: [{non_neg_integer(), pos_integer()}] | nil,
          audio_offset_ms: non_neg_integer(),
          estimated: boolean()
        }

  @spec from_char_alignment(String.t(), map(), keyword()) :: t()
  def from_char_alignment(text, alignment, opts) do
    characters = Map.get(alignment, "characters", [])
    starts = Map.get(alignment, "character_start_times_seconds", [])

    if is_list(characters) and is_list(starts) and Enum.all?(characters, &is_binary/1) and
         length(characters) == length(starts) and Enum.join(characters) == text and
         Enum.all?(starts, &(is_number(&1) and &1 >= 0)) do
      # Provider arrays can split a combining sequence; measure at grapheme byte boundaries.
      offsets =
        Enum.flat_map(Enum.zip(characters, starts), fn {char, start} ->
          List.duplicate(round(start * 1_000), byte_size(char))
        end)

      {spans, _} =
        Enum.map_reduce(String.graphemes(text), offsets, fn grapheme, remaining ->
          {{hd(remaining), 1}, Enum.drop(remaining, byte_size(grapheme))}
        end)

      build(text, spans, opts)
    else
      fallback(text, opts)
    end
  end

  @spec from_word_timestamps(String.t(), keyword()) :: t()
  def from_word_timestamps(text, opts) do
    words = Keyword.fetch!(opts, :words)

    if Enum.map_join(words, & &1.text) == text and
         Enum.all?(words, &(is_number(&1.start_ms) and &1.start_ms >= 0)) do
      spans = Enum.flat_map(words, fn word -> List.duplicate({round(word.start_ms), 1}, String.length(word.text)) end)
      # Graphemes spanning word boundaries require the character-aware fallback.
      if length(spans) == String.length(text), do: build(text, spans, opts), else: fallback(text, opts)
    else
      fallback(text, opts)
    end
  end

  @spec from_text_deltas(String.t(), keyword()) :: t()
  def from_text_deltas(text, opts) do
    duration = Keyword.get_lazy(opts, :duration_ms, fn -> audio_duration(Keyword.get(opts, :audio, [])) end)
    count = String.length(text)

    spans =
      if duration > 0,
        do: Enum.with_index(String.graphemes(text), fn _, i -> {trunc(i * duration / max(count, 1)), 1} end)

    event(text, spans, opts, true)
  end

  @spec heard_prefix(String.t(), [{non_neg_integer(), pos_integer()}] | nil, non_neg_integer()) :: String.t()
  def heard_prefix(text, nil, _played), do: text

  def heard_prefix(text, spans, played) do
    count = spans |> Enum.take_while(fn {offset, _} -> offset < played end) |> Enum.sum_by(&elem(&1, 1))
    String.slice(text, 0, count)
  end

  defp audio_duration(chunks) when is_list(chunks), do: Enum.sum_by(chunks, &audio_duration/1)

  defp audio_duration(%{format: format, data_b64: data}) do
    rates = %{pcm_16000: 16_000, pcm_24000: 24_000, pcm_44100: 44_100}

    case Base.decode64(data) do
      {:ok, bytes} when format in [:g711_ulaw, :g711_alaw] -> byte_size(bytes) / 8
      {:ok, bytes} -> byte_size(bytes) * 1_000 / (Map.fetch!(rates, format) * 2)
      :error -> 0
    end
  end

  defp fallback(text, opts) do
    :telemetry.execute([:voice_converse, :text_timing, :alignment_mismatch], %{count: 1}, %{})
    from_text_deltas(text, opts)
  end

  defp build(text, spans, opts) do
    {spans, _} =
      Enum.map_reduce(spans, 0, fn {offset, length}, last ->
        offset = max(offset, last)
        {{offset, length}, offset}
      end)

    event(text, spans, opts, false)
  end

  defp event(text, spans, opts, estimated) do
    offset = Keyword.get(opts, :audio_offset_ms, 0)

    %__MODULE__{
      turn_id: Keyword.fetch!(opts, :turn_id),
      text: text,
      chars: if(spans, do: Enum.map(spans, fn {ms, length} -> {ms + offset, length} end)),
      audio_offset_ms: offset,
      estimated: estimated
    }
  end
end
