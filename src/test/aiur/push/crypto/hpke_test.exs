defmodule Aiur.Push.Crypto.HpkeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aiur.Push.Crypto.{Hkdf, Hpke}

  @fixture_path "test/support/fixtures/push/rfc9180_a21.json"

  setup_all do
    fixture = @fixture_path |> File.read!() |> Jason.decode!()
    {:ok, fixture: decode_hex_fields(fixture)}
  end

  test "HKDF matches RFC 5869 test case 1" do
    ikm = :binary.copy(<<0x0B>>, 22)
    salt = Base.decode16!("000102030405060708090A0B0C", case: :upper)
    info = Base.decode16!("F0F1F2F3F4F5F6F7F8F9", case: :upper)

    prk = Hkdf.extract(salt, ikm)
    assert prk == Base.decode16!("077709362C2E32DF0DDC3F0DC47BBA6390B6C73BB50F9C3122EC844AD7C2B3E5", case: :upper)
    assert Hkdf.expand(prk, info, 42) == Base.decode16!("3CB25F25FAACD57A90434F64D0362F2A2D2D0A90CF1A5A4C5DB02D56ECC4C5BF34007208D5B887185865", case: :upper)
  end

  test "reproduces RFC 9180 A.2.1 sequence zero ciphertext", %{fixture: f} do
    assert {f.pkRm, f.skRm} == :crypto.generate_key(:eddh, :x25519, f.skRm)

    assert Hpke.seal(f.pkRm, f.info, f.aad, f.plaintext, ephemeral_private: f.skEm) == {f.enc, f.ciphertext}
    assert {:ok, f.plaintext} == Hpke.open(f.enc, f.skRm, f.info, f.aad, f.ciphertext)
  end

  property "seal then open round-trips arbitrary plaintexts" do
    check all(plaintext <- binary(max_length: 2600), max_runs: 200) do
      {recipient_pub, recipient_priv} = :crypto.generate_key(:eddh, :x25519)
      info = "property info"
      aad = "property aad"
      {enc, ciphertext} = Hpke.seal(recipient_pub, info, aad, plaintext)

      assert {:ok, plaintext} == Hpke.open(enc, recipient_priv, info, aad, ciphertext)
    end
  end

  test "tampering, wrong context, and malformed input fail uniformly", %{fixture: f} do
    for index <- 0..(byte_size(f.enc) - 1) do
      assert {:error, :open_failed} == Hpke.open(f.enc |> flip_byte(index), f.skRm, f.info, f.aad, f.ciphertext)
    end

    for index <- 0..(byte_size(f.ciphertext) - 1) do
      assert {:error, :open_failed} == Hpke.open(f.enc, f.skRm, f.info, f.aad, flip_byte(f.ciphertext, index))
    end

    assert {:error, :open_failed} == Hpke.open(f.enc, f.skRm, f.info, "wrong aad", f.ciphertext)
    assert {:error, :open_failed} == Hpke.open(f.enc, f.skRm, "wrong info", f.aad, f.ciphertext)
    assert {:error, :open_failed} == Hpke.open(<<1>>, f.skRm, f.info, f.aad, f.ciphertext)
    assert {:error, :open_failed} == Hpke.open(f.enc, <<1>>, f.info, f.aad, f.ciphertext)
    assert {:error, :open_failed} == Hpke.open(f.enc, f.skRm, f.info, f.aad, <<0::128>>)
  end

  test "rejects an all-zero X25519 peer and generates a fresh ephemeral each time", %{fixture: f} do
    assert_raise ArgumentError, fn -> Hpke.seal(<<0::256>>, f.info, f.aad, f.plaintext) end
    assert {:error, :open_failed} == Hpke.open(<<0::256>>, f.skRm, f.info, f.aad, f.ciphertext)
    assert {first, _} = Hpke.seal(f.pkRm, f.info, f.aad, f.plaintext)
    assert {second, _} = Hpke.seal(f.pkRm, f.info, f.aad, f.plaintext)
    refute first == second
  end

  defp decode_hex_fields(map) do
    Map.new(map, fn
      {"source", value} ->
        {:source, value}

      {key, value} when key in ["info", "ikmE", "skEm", "pkEm", "skRm", "pkRm", "enc", "shared_secret", "key", "base_nonce", "plaintext", "aad", "ciphertext"] ->
        {String.to_atom(key), Base.decode16!(value, case: :lower)}
    end)
  end

  defp flip_byte(binary, index) do
    <<prefix::binary-size(index), byte, suffix::binary>> = binary
    prefix <> <<Bitwise.bxor(byte, 1)>> <> suffix
  end
end
