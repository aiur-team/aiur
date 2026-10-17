defmodule Aiur.BuildGate.HookSnapshot do
  @moduledoc """
  Content-addressed copy of the build-gate hook outside the release tree.

  A live agent keeps the `BASH_ENV` it launched with, and the hook finds its
  parts and holder helper beside that file. A release rebuild replaces `priv/`,
  so an agent started before the rebuild would lose its build admission
  (#4489). Each distinct hook is copied once to `<root>/<digest>/`, so every
  path an existing agent holds stays readable. A snapshot is reused only while
  its files still match the release; a damaged one is republished. Snapshots
  are read-only, so a stray edit cannot reach agents before that check runs.
  """

  # ponytail: snapshots are never pruned; each is ~115 KiB and only a changed hook adds one.
  # Read by name, so a missing release tree is an error rather than an empty snapshot.
  @files ~w(build_gate.bash browser_build_gate.bash build_priority.bash build_gate_holder.py)
  @globs ~w(build_gate/*.bash build_gate_holder_lib/*.py)

  # A stage older than this was left by a BEAM that died before its rename.
  @stale_stage_seconds 3600

  @spec ensure(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def ensure(source_dir, root) do
    with {:ok, files} <- read_files(source_dir) do
      target = Path.join(root, digest(files))
      remove_stale_stages(root)

      if intact?(target, files), do: {:ok, hook(target)}, else: publish(files, root, target)
    end
  end

  defp hook(target), do: Path.join(target, "build_gate.bash")

  defp intact?(target, files), do: Enum.all?(files, fn {relative, contents} -> File.read(Path.join(target, relative)) == {:ok, contents} end)

  defp remove_stale_stages(root) do
    cutoff = System.os_time(:second) - @stale_stage_seconds

    for stage <- Path.wildcard(Path.join(root, ".stage-*"), match_dot: true), match?({:ok, %File.Stat{mtime: mtime}} when mtime < cutoff, File.lstat(stage, time: :posix)) do
      remove(stage)
    end
  end

  # rm_rf cannot clear a read-only directory, so make each one writable first.
  defp remove(dir) do
    for path <- [dir | Path.wildcard(Path.join(dir, "**"), match_dot: true)], match?({:ok, %File.Stat{type: :directory}}, File.lstat(path)) do
      File.chmod(path, 0o755)
    end

    File.rm_rf(dir)
  end

  defp read_files(source_dir) do
    files =
      Enum.map(@files, &Path.join(source_dir, &1))
      |> Enum.concat(Enum.flat_map(@globs, &Path.wildcard(Path.join(source_dir, &1))))
      |> Enum.sort()
      |> Enum.map(&{Path.relative_to(&1, source_dir), File.read(&1)})

    case Enum.find(files, &match?({_relative, {:error, _reason}}, &1)) do
      nil -> {:ok, Enum.map(files, fn {relative, {:ok, contents}} -> {relative, contents} end)}
      {relative, {:error, reason}} -> {:error, {:read_hook_file, relative, reason}}
    end
  end

  defp digest(files) do
    files
    |> Enum.map(fn {relative, contents} -> [relative, 0, Integer.to_string(byte_size(contents)), 0, contents] end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Stage then rename, so a reader never sees a partially written snapshot.
  defp publish(files, root, target) do
    stage = Path.join(root, ".stage-#{Path.basename(target)}-#{System.unique_integer([:positive])}")

    result =
      with :ok <- File.mkdir_p(stage),
           :ok <- write_files(files, stage),
           :ok <- seal(stage) do
        # A damaged snapshot is replaced, not trusted.
        _ = remove(target)
        rename(stage, target, files)
      end

    _ = remove(stage)
    result
  end

  defp rename(stage, target, files) do
    case File.rename(stage, target) do
      :ok -> {:ok, hook(target)}
      # A concurrent publisher won the race with identical content.
      {:error, _reason} = error -> if intact?(target, files), do: {:ok, hook(target)}, else: error
    end
  end

  defp write_files(files, stage) do
    Enum.reduce_while(files, :ok, fn {relative, contents}, :ok ->
      path = Path.join(stage, relative)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, contents),
           :ok <- File.chmod(path, 0o444) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp seal(stage) do
    Enum.reduce_while([stage | Enum.filter(Path.wildcard(Path.join(stage, "*")), &File.dir?/1)], :ok, fn dir, :ok ->
      case File.chmod(dir, 0o555) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
