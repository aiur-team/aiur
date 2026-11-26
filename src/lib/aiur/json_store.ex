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

  alias Aiur.Fs

  @doc """
  Writes `term` as JSON to `path`. Raises on any failure.

  Creates parent directories on demand. Writes to `path <> ".tmp"` first,
  fsyncs the descriptor, then renames into place. Atomic from any concurrent
  reader's perspective.
  """
  @spec write!(Path.t(), term(), keyword()) :: :ok
  def write!(path, term, opts \\ []) when is_binary(path) do
    case write(path, term, opts) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "write", path: path
    end
  end

  @doc "Like `write!/3`, but returns `{:error, reason}` instead of raising."
  @spec write(Path.t(), term(), keyword()) :: :ok | {:error, term()}
  def write(path, term, opts \\ []) when is_binary(path) do
    # Only a failed mkdir is observed: its `:ok` would close the disk-full episode before the write itself runs.
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> Fs.atomic_write(path, Jason.encode!(term), [fsync: true] ++ Keyword.take(opts, [:mode]))
      error -> Aiur.DiskFull.observe(path, error)
    end
  end

  @doc """
  Writes like `write/3` but never fails: a failed write is logged and dropped,
  and the caller keeps its in-memory state (#7925). For state a server can
  rebuild or replay, where crashing on a full disk would cost more than a
  stale file on the next boot.
  """
  @spec write_or_drop(Path.t(), term(), keyword()) :: :ok
  def write_or_drop(path, term, opts \\ []) do
    with {:error, reason} <- write(path, term, opts) do
      Logger.warning("json_store phase=write_dropped path=#{path} reason=#{inspect(reason)}")
      :ok
    end
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
