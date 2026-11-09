defmodule Aiur.UnitsCLIBuildTest do
  use ExUnit.Case, async: true

  test "reports only the daemon release stamp identity, including missing fields" do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    root = Path.join(System.tmp_dir!(), "newsletter-build-#{suffix}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    path = Path.join(root, "stamp")
    sha = String.duplicate("a", 40)
    built_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    File.write!(path, "source_sha=#{sha}\nbuilt_at=#{built_at}\nrepo_root=private\n")
    opts = [payload_fun: fn -> %{} end, build_stamp_path: path]

    assert {:ok, envelope} = Aiur.UnitsCLI.build(opts)
    assert envelope["auxiliary"]["running_build"] == %{"sha" => sha, "built_at" => built_at}

    File.write!(path, "source_sha=#{sha}\n")
    assert {:ok, partial} = Aiur.UnitsCLI.build(opts)
    assert partial["auxiliary"]["running_build"] == %{"sha" => sha, "built_at" => nil}

    File.rm!(path)
    assert {:ok, missing} = Aiur.UnitsCLI.build(opts)
    assert missing["auxiliary"]["running_build"] == %{"sha" => nil, "built_at" => nil}
  end
end
