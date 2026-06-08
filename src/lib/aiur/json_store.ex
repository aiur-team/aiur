defmodule Aiur.JsonStore do
  @moduledoc """
  Atomic-rename JSON file helper for durable persistence.

  Provides crash-safe writes via the `write to .tmp + fsync + rename` pattern.
  On ext4 with `data=ordered` (default) and on XFS, the rename is atomic from
  the perspective of any reader — they see either the pre-write or post-write
  state, never partial JSON. The `fsync` before rename guarantees that the
  data is on disk before the rename is observable, which matters on filesystems
  that don't journal data writes.

  Used by `Aiur.Events.IdGenerator` for the persistent monotonic counter and
  by `Aiur.Events.SubscriptionStore` for per-issue subscription state — both
  need crash-safe small JSON files without depending on a database.

  Reads are graceful: missing files return the caller-supplied default; corrupt
  files return `{:error, reason}` so callers can decide whether to fall back
  or refuse to start.
  """

  require Logger

  @doc """
  Writes `term` as JSON to `path`. Raises on any failure.

  Creates parent directories on demand. Writes to `path <> ".tmp"` first,
  fsyncs the descriptor, then renames into place. Atomic from any concurrent
  reader's perspective.
  """
  @spec write!(Path.t(), term()) :: :ok
  def write!(path, term) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))
    # Unique tmp suffix so concurrent writers don't clobber each other's
    # staging file; on POSIX, rename is atomic and last-writer-wins for
    # the target path, which is the durability contract we want.
    tmp_path = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))
    encoded = Jason.encode!(term)

    {:ok, fd} = :file.open(tmp_path, [:write, :binary, :raw])

    try do
      :ok = :file.write(fd, encoded)
      :ok = :file.sync(fd)
    after
      :ok = :file.close(fd)
    end

    :ok = File.rename(tmp_path, path)
    :ok
  end

  @doc """
  Reads JSON from `path`. Returns `{:ok, term}` on success, `{:ok, default}`
  if the file doesn't exist, or `{:error, reason}` if the file exists but
  can't be parsed.
  """
  @spec read(Path.t(), term()) :: {:ok, term()} | {:error, term()}
  def read(path, default \\ nil) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, term} -> {:ok, term}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:ok, default}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
