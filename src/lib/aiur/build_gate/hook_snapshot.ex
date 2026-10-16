defmodule Aiur.BuildGate.HookSnapshot do
  @moduledoc """
  Content-addressed copy of the build-gate hook outside the release tree.

  A live agent keeps the `BASH_ENV` it launched with, and the hook finds its
  parts and holder helper beside that file. A release rebuild replaces `priv/`,
  so an agent started before the rebuild would lose its build admission
  (#4489). Each distinct hook is copied once to `<root>/<digest>/` and never
  rewritten, so every path an existing agent holds stays readable.
  """

  # ponytail: snapshots are never pruned; each is ~100 KiB and only a changed hook adds one.
  @patterns ~w(
    build_gate.bash browser_build_gate.bash build_priority.bash build_gate_holder.py
    build_gate/*.bash build_gate_holder_lib/*.py
  )

  @spec ensure(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def ensure(source_dir, root) do
    with {:ok, files} <- read_files(source_dir) do
      target = Path.join(root, digest(files))
      hook = Path.join(target, "build_gate.bash")

      if File.regular?(hook), do: {:ok, hook}, else: publish(files, root, target, hook)
    end
  end

  defp read_files(source_dir) do
    files =
      @patterns
      |> Enum.flat_map(&Path.wildcard(Path.join(source_dir, &1)))
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
  defp publish(files, root, target, hook) do
    stage = Path.join(root, ".stage-#{Path.basename(target)}-#{System.unique_integer([:positive])}")

    result =
      with :ok <- File.mkdir_p(stage),
           :ok <- write_files(files, stage) do
        case File.rename(stage, target) do
          :ok -> {:ok, hook}
          # A concurrent publisher won the race with identical content.
          {:error, _reason} = error -> if File.regular?(hook), do: {:ok, hook}, else: error
        end
      end

    _ = File.rm_rf(stage)
    result
  end

  defp write_files(files, stage) do
    Enum.reduce_while(files, :ok, fn {relative, contents}, :ok ->
      path = Path.join(stage, relative)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, contents) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end
end
