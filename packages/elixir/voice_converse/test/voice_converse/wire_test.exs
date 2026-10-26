defmodule VoiceConverse.WireTest do
  use ExUnit.Case, async: true

  alias VoiceConverse.Wire

  @contract_fixtures Path.expand("../../../../aiur-contracts/fixtures/voice-converse.v1.json", __DIR__)
  @fixtures Path.expand("../fixtures/wire/v1.jsonl", __DIR__)
  @schema_validator Path.expand("../../../../aiur-contracts/scripts/validate-voice-converse-frame.mjs", __DIR__)

  test "every v1 golden frame round-trips byte-for-byte and validates against the public schema" do
    golden_frames = @fixtures |> File.stream!() |> Enum.map(&String.trim/1)

    assert Jason.decode!("[" <> Enum.join(golden_frames, ",") <> "]") == Jason.decode!(File.read!(@contract_fixtures))

    for json <- golden_frames do
      frame = Jason.decode!(json)
      assert {:ok, encoded} = Wire.encode(frame)
      assert encoded == json
      assert {:ok, ^frame} = Wire.decode(encoded)
      assert {_, 0} = System.cmd("node", [@schema_validator, encoded], stderr_to_stdout: true)
    end
  end

  test "rejects a frame with an unknown type or version" do
    assert {:error, :invalid_frame} = Wire.decode(~s({"v":1,"type":"unknown"}))
    assert {:error, :unsupported_version} = Wire.decode(~s({"v":2,"type":"end"}))
    assert {:error, :invalid_frame} = Wire.decode(~s({"v":1,"type":"audio"}))
  end
end
