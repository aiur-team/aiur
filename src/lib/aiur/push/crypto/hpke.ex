defmodule Aiur.Push.Crypto.Hpke do
  @moduledoc "Single-shot RFC 9180 base mode for X25519, HKDF-SHA256 and ChaCha20-Poly1305."

  alias Aiur.Push.Crypto.Hkdf

  @kem_suite "KEM" <> <<0x0020::16>>
  @hpke_suite "HPKE" <> <<0x0020::16, 0x0001::16, 0x0003::16>>
  @tag_length 16

  @spec seal(<<_::256>>, binary(), binary(), binary(), keyword()) :: {<<_::256>>, binary()}
  def seal(recipient_pub, info, aad, plaintext, opts \\ [])
      when is_binary(recipient_pub) and byte_size(recipient_pub) == 32 and is_binary(info) and is_binary(aad) and is_binary(plaintext) do
    {ephemeral_pub, ephemeral_priv} = ephemeral_keypair(opts)
    shared = dh_shared_secret(ephemeral_priv, recipient_pub, :seal)
    {key, nonce} = key_schedule(shared, ephemeral_pub <> recipient_pub, info)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:chacha20_poly1305, key, nonce, plaintext, aad, true)
    {ephemeral_pub, ciphertext <> tag}
  end

  @spec open(binary(), binary(), binary(), binary(), binary()) :: {:ok, binary()} | {:error, :open_failed}
  def open(enc, recipient_priv, info, aad, ciphertext)
      when is_binary(enc) and byte_size(enc) == 32 and is_binary(recipient_priv) and byte_size(recipient_priv) == 32 and
             is_binary(info) and is_binary(aad) and is_binary(ciphertext) and byte_size(ciphertext) >= @tag_length do
    open_validated(enc, recipient_priv, info, aad, ciphertext)
  rescue
    _ -> {:error, :open_failed}
  catch
    _, _ -> {:error, :open_failed}
  end

  def open(_enc, _recipient_priv, _info, _aad, _ciphertext), do: {:error, :open_failed}

  defp open_validated(enc, recipient_priv, info, aad, ciphertext) do
    {recipient_pub, _} = :crypto.generate_key(:eddh, :x25519, recipient_priv)
    shared = dh_shared_secret(recipient_priv, enc, :open)
    {key, nonce} = key_schedule(shared, enc <> recipient_pub, info)
    decrypt(key, nonce, aad, ciphertext)
  end

  defp decrypt(key, nonce, aad, ciphertext) do
    body_length = byte_size(ciphertext) - @tag_length
    <<body::binary-size(body_length), tag::binary-size(@tag_length)>> = ciphertext

    case :crypto.crypto_one_time_aead(:chacha20_poly1305, key, nonce, body, aad, tag, false) do
      :error -> {:error, :open_failed}
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
    end
  end

  defp ephemeral_keypair(opts) do
    case Keyword.fetch(opts, :ephemeral_private) do
      {:ok, private} when is_binary(private) and byte_size(private) == 32 ->
        {public, _} = :crypto.generate_key(:eddh, :x25519, private)
        {public, private}

      {:ok, _} ->
        raise ArgumentError, "ephemeral_private must be a 32-byte X25519 private key"

      :error ->
        :crypto.generate_key(:eddh, :x25519)
    end
  end

  defp dh_shared_secret(private, public, mode) do
    shared = :crypto.compute_key(:eddh, public, private, :x25519)
    if shared == <<0::256>>, do: invalid_dh(mode)
    shared
  rescue
    _ -> invalid_dh(mode)
  end

  defp invalid_dh(:open), do: throw(:open_failed)
  defp invalid_dh(:seal), do: raise(ArgumentError, "recipient public key produces an all-zero X25519 secret")

  defp key_schedule(shared, kem_context, info) do
    eae_prk = labeled_extract(@kem_suite, <<>>, "eae_prk", shared)
    shared_secret = labeled_expand(@kem_suite, eae_prk, "shared_secret", kem_context, 32)
    psk_id_hash = labeled_extract(@hpke_suite, <<>>, "psk_id_hash", <<>>)
    info_hash = labeled_extract(@hpke_suite, <<>>, "info_hash", info)
    context = <<0>> <> psk_id_hash <> info_hash
    secret = labeled_extract(@hpke_suite, shared_secret, "secret", <<>>)
    {labeled_expand(@hpke_suite, secret, "key", context, 32), labeled_expand(@hpke_suite, secret, "base_nonce", context, 12)}
  end

  defp labeled_extract(suite, salt, label, ikm), do: Hkdf.extract(salt, "HPKE-v1" <> suite <> label <> ikm)
  defp labeled_expand(suite, prk, label, info, length), do: Hkdf.expand(prk, <<length::16>> <> "HPKE-v1" <> suite <> label <> info, length)
end
