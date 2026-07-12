defmodule Aiur.PathSafetyTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Aiur.PathSafety

  describe "contained?/2" do
    test "a subpath of root is contained", %{tmp_dir: tmp_dir} do
      candidate = Path.join(tmp_dir, "child")
      assert {:ok, %{root: root, candidate: ^candidate}} = PathSafety.contained?(tmp_dir, candidate)
      assert root == Path.expand(tmp_dir)
    end

    test "root itself is contained (equality is not itself an error)", %{tmp_dir: tmp_dir} do
      assert {:ok, %{root: same, candidate: same}} = PathSafety.contained?(tmp_dir, tmp_dir)
    end

    test "a path outside root is rejected", %{tmp_dir: tmp_dir} do
      outside = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer([:positive])}")
      assert PathSafety.contained?(tmp_dir, outside) == {:error, :outside_root}
    end

    test "a traversal sequence that escapes root is rejected", %{tmp_dir: tmp_dir} do
      escaped = Path.join(tmp_dir, "../escaped")
      assert PathSafety.contained?(tmp_dir, escaped) == {:error, :outside_root}
    end

    test "a symlink that resolves outside root is rejected", %{tmp_dir: tmp_dir} do
      outside_dir = Path.join(System.tmp_dir!(), "path-safety-outside-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside_dir)
      on_exit(fn -> File.rm_rf!(outside_dir) end)

      link = Path.join(tmp_dir, "escape_link")
      File.ln_s!(outside_dir, link)

      assert PathSafety.contained?(tmp_dir, link) == {:error, :outside_root}
    end

    test "a symlink that resolves within root is contained", %{tmp_dir: tmp_dir} do
      real = Path.join(tmp_dir, "real")
      File.mkdir_p!(real)
      link = Path.join(tmp_dir, "link")
      File.ln_s!(real, link)

      assert {:ok, %{candidate: canonical}} = PathSafety.contained?(tmp_dir, link)
      assert canonical == Path.expand(real)
    end
  end
end
