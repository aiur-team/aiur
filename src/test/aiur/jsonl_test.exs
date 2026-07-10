defmodule Aiur.JsonlTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Aiur.Jsonl

  test "decode_line/1 returns a decoded JSON object" do
    assert {:ok, %{"event" => "alert"}} = Jsonl.decode_line(~s({"event":"alert"}))
  end

  test "decode_line/1 tolerates surrounding whitespace and a trailing newline" do
    assert {:ok, %{"event" => "alert"}} = Jsonl.decode_line(~s(  {"event":"alert"}\n))
  end

  test "decode_line/1 skips malformed JSON" do
    assert Jsonl.decode_line("{not valid json") == :skip
  end

  test "decode_line/1 skips valid non-object JSON" do
    assert Jsonl.decode_line("[1,2]") == :skip
    assert Jsonl.decode_line("42") == :skip
  end

  test "stream/1 yields only decoded maps in file order", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "events.ndjson")

    File.write!(path, """
    {"event":"first"}
    {not valid json
    [1,2]
    {"event":"second"}
    """)

    assert Enum.to_list(Jsonl.stream(path)) == [
             %{"event" => "first"},
             %{"event" => "second"}
           ]
  end
end
