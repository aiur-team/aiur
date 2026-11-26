defmodule Aiur.Experiments.Auto.BuildStampTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.Auto.BuildStamp

  test "stamp parses only known SHA and dirty evidence" do
    assert BuildStamp.parse("source_sha=abc\ndirty=no\nbuilt_at=now\n") == %{source_sha: "abc", dirty: false}
    assert BuildStamp.parse("source_sha=abcdef\ndirty=yes\n") == %{source_sha: "abcdef", dirty: true}
    assert BuildStamp.parse("garbage\nsource_sha=unknown\ndirty=maybe") == %{source_sha: nil, dirty: nil}
    assert BuildStamp.read(nil) == %{source_sha: nil, dirty: nil}
    assert BuildStamp.read(Path.join(System.tmp_dir!(), "absent-stamp-#{System.unique_integer([:positive])}")) == %{source_sha: nil, dirty: nil}
  end

  test "nightly and build suffixes do not change the base version" do
    assert BuildStamp.base_version("0.0.10-nightly.1a2b+build") == "0.0.10"
    assert BuildStamp.base_version("weird") == :unknown
  end
end
