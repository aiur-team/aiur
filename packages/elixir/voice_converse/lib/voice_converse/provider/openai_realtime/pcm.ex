defmodule VoiceConverse.Provider.OpenAIRealtime.PCM do
  @moduledoc false

  # Linear 3:2 interpolation; retain incomplete pairs across websocket chunks.
  @spec convert(String.t(), binary()) :: {:ok, String.t(), binary()} | {:error, :invalid_audio}
  def convert(base64, tail) do
    with {:ok, pcm} <- Base.decode64(base64),
         true <- rem(byte_size(pcm), 2) == 0 do
      {output, tail} = upsample(tail <> pcm, [])
      {:ok, Base.encode64(output), tail}
    else
      _ -> {:error, :invalid_audio}
    end
  end

  defp upsample(<<a::little-signed-16, b::little-signed-16, c::little-signed-16, rest::binary>>, chunks) do
    first = div(2 * b + c, 3)
    middle = div(a + 2 * b, 3)

    upsample(<<c::little-signed-16, rest::binary>>, [
      <<a::little-signed-16, middle::little-signed-16, first::little-signed-16>> | chunks
    ])
  end

  defp upsample(tail, chunks), do: {chunks |> Enum.reverse() |> IO.iodata_to_binary(), tail}
end
