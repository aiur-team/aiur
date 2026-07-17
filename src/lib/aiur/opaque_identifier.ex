defmodule Aiur.OpaqueIdentifier do
  @moduledoc """
  Shared boundary validation for opaque identifiers safe to retain or expose.

  Opaque identifiers are bounded, valid UTF-8, restricted to the common
  identifier alphabet, and rejected when they contain a known credential.
  """

  alias Aiur.SecretRedactor

  @default_max_bytes 128

  @spec normalize(term(), pos_integer()) :: String.t() | nil
  def normalize(value, max_bytes \\ @default_max_bytes)

  def normalize(value, max_bytes)
      when is_binary(value) and is_integer(max_bytes) and max_bytes > 0 and
             byte_size(value) <= max_bytes do
    if String.valid?(value) and value != "" and
         Regex.match?(~r/^[A-Za-z0-9._:-]+$/, value) and
         SecretRedactor.redact(value) == value,
       do: value
  end

  def normalize(_value, _max_bytes), do: nil
end
