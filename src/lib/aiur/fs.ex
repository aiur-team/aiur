defmodule Aiur.Fs do
  @moduledoc """
  Shared filesystem primitives.

  `atomic_write/3` writes to a uniquely-suffixed sibling temp file and
  renames it into place, so any concurrent reader sees either the previous
  contents or the complete new contents — never a prefix. rename(2) within
  a directory is atomic on POSIX; last-writer-wins for the target path.
  Pass `fsync: true` when the data must be on disk before the rename is
  observable (crash-safe persistence, see `Aiur.JsonStore`).

  Does not create parent directories — callers that need that (JsonStore)
  mkdir_p themselves. The staged temp file is removed on any failure.
  """

  @spec atomic_write(Path.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def atomic_write(path, contents, opts \\ []) when is_binary(path) do
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    result =
      if Keyword.get(opts, :fsync, false) do
        write_with_fsync(tmp, contents)
      else
        File.write(tmp, contents)
      end

    case result do
      :ok -> rename_or_cleanup(tmp, path)
      {:error, reason} -> cleanup_error(tmp, reason)
    end
  end

  defp rename_or_cleanup(tmp, path) do
    case File.rename(tmp, path) do
      :ok -> :ok
      {:error, reason} -> cleanup_error(tmp, reason)
    end
  end

  defp cleanup_error(tmp, reason) do
    _ = File.rm(tmp)
    {:error, reason}
  end

  defp write_with_fsync(tmp, contents) do
    with {:ok, fd} <- :file.open(tmp, [:write, :binary, :raw]) do
      try do
        with :ok <- :file.write(fd, contents) do
          :file.sync(fd)
        end
      after
        :ok = :file.close(fd)
      end
    end
  end
end
