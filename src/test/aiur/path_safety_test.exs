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
      outside = Aiur.TestSupport.tmp_root!("outside")
      assert PathSafety.contained?(tmp_dir, outside) == {:error, :outside_root}
    end

    test "a traversal sequence that escapes root is rejected", %{tmp_dir: tmp_dir} do
      escaped = Path.join(tmp_dir, "../escaped")
      assert PathSafety.contained?(tmp_dir, escaped) == {:error, :outside_root}
    end

    test "a symlink that resolves outside root is rejected", %{tmp_dir: tmp_dir} do
      outside_dir = Aiur.TestSupport.tmp_root!("path-safety-outside")
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

  describe "canonicalize/1 symlink bounds" do
    test "a symlink cycle fails promptly instead of wedging the caller", %{tmp_dir: tmp_dir} do
      first = Path.join(tmp_dir, "first")
      second = Path.join(tmp_dir, "second")
      File.ln_s!(second, first)
      File.ln_s!(first, second)

      task = Task.async(fn -> PathSafety.canonicalize(first) end)

      result =
        case Task.yield(task, 2_000) do
          {:ok, value} ->
            value

          nil ->
            Task.shutdown(task, :brutal_kill)
            :timed_out
        end

      assert {:error, {:path_canonicalize_failed, ^first, :symlink_cycle}} = result
    end

    test "a symlink chain beyond the traversal cap fails like ELOOP", %{tmp_dir: tmp_dir} do
      first = create_symlink_chain(tmp_dir, 41)

      assert {:error, {:path_canonicalize_failed, ^first, :too_many_symlinks}} =
               PathSafety.canonicalize(first)
    end

    test "a symlink chain at the traversal cap still resolves", %{tmp_dir: tmp_dir} do
      first = create_symlink_chain(tmp_dir, 40)

      assert {:ok, canonical} = PathSafety.canonicalize(first)
      assert canonical == Path.join(tmp_dir, "target")
    end
  end

  defp create_symlink_chain(tmp_dir, count) do
    target = Path.join(tmp_dir, "target")
    File.write!(target, "ok")

    Enum.each(count..1//-1, fn index ->
      link = Path.join(tmp_dir, "link-#{index}")
      next = if index == count, do: target, else: Path.join(tmp_dir, "link-#{index + 1}")
      File.ln_s!(next, link)
    end)

    Path.join(tmp_dir, "link-1")
  end
end
