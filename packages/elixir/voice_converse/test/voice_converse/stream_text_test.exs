defmodule VoiceConverse.Session.StreamTextTest do
  use ExUnit.Case, async: true
  alias VoiceConverse.Redact
  alias VoiceConverse.Session.StreamText

  # {full turn, secret tokens that must never reach a partial}
  @cases [
    {"say Bearer abcdefgh12345 ok", ["abcdefgh12345"]},
    {"say bearer abcdefgh12345 ok", ["abcdefgh12345"]},
    {"key sk-abcdefgh1234 ok", ["abcdefgh1234"]},
    {"key ghp_abcdefgh1234 ok", ["abcdefgh1234"]},
    {"key xi_abcdefgh1234 ok", ["abcdefgh1234"]},
    {"key gho-abcdefgh1234 ok", ["abcdefgh1234"]},
    {"key ghs_abcdefgh1234 ok", ["abcdefgh1234"]},
    {"see https://user:password@host ok", ["user:password"]},
    {"a sk-abcdefgh1234 b ghp_ijklmnop5678 c", ["abcdefgh1234", "ijklmnop5678"]},
    {"say Bearer sk-abcdefgh12345 ok", ["abcdefgh12345"]},
    {"say Bearer    abcdefgh12345 ok", ["abcdefgh12345"]}
  ]

  test "every 2-chunk, 3-chunk and per-byte split keeps secrets out of streamed partials" do
    count =
      for {full, secrets} <- @cases, chunks <- splits(full), reduce: 0 do
        count ->
          {stream, partials} =
            Enum.reduce(chunks, {%{raw: "", sent: ""}, []}, fn chunk, {stream, acc} ->
              {stream, text} = StreamText.step(stream, chunk, &Redact.redact/1)
              {stream, [text | acc]}
            end)

          drained = StreamText.drain(stream, &Redact.redact/1)
          sent = [drained | partials] |> Enum.reject(&is_nil/1) |> Enum.reverse() |> Enum.join()
          final = Redact.redact(full)

          for secret <- secrets,
              do: refute(String.contains?(sent, secret), inspect({chunks, sent}))

          # Partials either rebuild the masked turn or fall silent when redaction
          # rewrote text already sent (the final event then carries the masked turn).
          assert sent == final or not String.starts_with?(final, sent), inspect({chunks, sent})
          count + 1
      end

    assert count > 4_000
  end

  defp splits(text) do
    size = byte_size(text)
    cut = fn points -> chunks(text, [0 | points] ++ [size]) end
    bytes = for i <- 0..(size - 1), do: binary_part(text, i, 1)
    two = for i <- 1..(size - 1), do: cut.([i])
    three = for i <- 1..(size - 2), j <- (i + 1)..(size - 1), do: cut.([i, j])
    [bytes | two ++ three]
  end

  defp chunks(text, points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> binary_part(text, a, b - a) end)
  end
end
