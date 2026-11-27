defmodule Aiur.Push.Crypto.Hkdf do
  @moduledoc "HKDF-SHA256 extract and expand operations."

  @hash_length 32

  @spec extract(binary(), binary()) :: binary()
  def extract(salt, ikm) when is_binary(salt) and is_binary(ikm) do
    :crypto.mac(:hmac, :sha256, if(salt == <<>>, do: :binary.copy(<<0>>, @hash_length), else: salt), ikm)
  end

  @spec expand(binary(), binary(), non_neg_integer()) :: binary()
  def expand(prk, info, length) when is_binary(prk) and is_binary(info) and is_integer(length) and length >= 0 and length <= 255 * @hash_length do
    blocks = div(length + @hash_length - 1, @hash_length)

    expand_blocks(prk, info, blocks, 1, <<>>, <<>>)
    |> binary_part(0, length)
  end

  def expand(_prk, _info, _length), do: raise(ArgumentError, "HKDF output length must be between 0 and 8160 bytes")

  defp expand_blocks(_prk, _info, blocks, counter, _previous, output) when counter > blocks, do: output

  defp expand_blocks(prk, info, blocks, counter, previous, output) do
    next = :crypto.mac(:hmac, :sha256, prk, previous <> info <> <<counter>>)
    expand_blocks(prk, info, blocks, counter + 1, next, output <> next)
  end
end
