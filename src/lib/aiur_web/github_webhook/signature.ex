defmodule AiurWeb.GithubWebhook.Signature do
  @moduledoc """
  HMAC-SHA256 verification for GitHub webhook deliveries.

  GitHub signs the exact bytes it sent and presents the digest in
  `X-Hub-Signature-256` as `sha256=<lowercase hex>`. Verification therefore has
  to run against the raw request body — re-encoding a parsed map produces
  different bytes and a digest that never matches.

  The legacy SHA-1 `X-Hub-Signature` header is deliberately unsupported: it is
  not accepted as a fallback anywhere in this module.
  """

  @prefix "sha256="
  @digest_bytes 32
  @hex_length @digest_bytes * 2

  @typedoc "Why a delivery failed verification. Never contains secret material."
  @type error :: :missing_signature | :malformed_signature | :signature_mismatch

  @doc """
  Verifies `raw_body` against the presented `X-Hub-Signature-256` header value.

  `header_values` is the raw list returned by `Plug.Conn.get_req_header/2`, so
  an absent header (`[]`) and an ambiguous duplicated header (more than one
  value) both fail closed.
  """
  @spec verify(binary(), [String.t()], binary()) :: :ok | {:error, error()}
  def verify(raw_body, header_values, secret)

  def verify(raw_body, [header], secret) when is_binary(raw_body) and is_binary(header) and is_binary(secret) do
    with {:ok, presented} <- decode_header(header) do
      expected = :crypto.mac(:hmac, :sha256, secret, raw_body)

      # Constant-time comparison: `==` on binaries short-circuits at the first
      # differing byte and leaks the signature one byte at a time.
      if Plug.Crypto.secure_compare(presented, expected), do: :ok, else: {:error, :signature_mismatch}
    end
  end

  def verify(_raw_body, [], _secret), do: {:error, :missing_signature}
  def verify(_raw_body, _ambiguous_or_invalid, _secret), do: {:error, :malformed_signature}

  defp decode_header(@prefix <> hex) when byte_size(hex) == @hex_length do
    case Base.decode16(hex, case: :mixed) do
      {:ok, digest} -> {:ok, digest}
      :error -> {:error, :malformed_signature}
    end
  end

  defp decode_header(_header), do: {:error, :malformed_signature}
end
