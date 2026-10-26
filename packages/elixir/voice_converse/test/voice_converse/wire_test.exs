defmodule VoiceConverse.WireTest do
  use ExUnit.Case, async: true

  alias VoiceConverse.Wire

  @fixtures Path.expand("../../../../aiur-contracts/fixtures/voice-converse.v1.json", __DIR__)

  test "every v1 golden frame round-trips through the wire codec" do
    for frame <- Jason.decode!(File.read!(@fixtures)) do
      assert {:ok, encoded} = Wire.encode(frame)
      assert {:ok, ^frame} = Wire.decode(encoded)
    end
  end

  test "rejects a frame with an unknown type or version" do
    assert {:error, :invalid_frame} = Wire.decode(~s({"v":1,"type":"unknown"}))
    assert {:error, :unsupported_version} = Wire.decode(~s({"v":2,"type":"end"}))
    assert {:error, :invalid_frame} = Wire.decode(~s({"v":1,"type":"audio"}))
  end
end
