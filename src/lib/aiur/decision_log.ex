defmodule Aiur.DecisionLog do
  @moduledoc """
  Crash-aware append/replay primitives for the canonical
  `decisions.ndjson` audit stream.

  Every accepted event is one newline-terminated JSON object, appended
  through a raw file descriptor and fsynced before the caller is told
  it's durable. The first time the canonical directory or file is
  created, `Aiur.Fs.sync_filesystem/0` is also called once, so the new
  directory entry itself survives a crash — a file's own fsync never
  syncs its parent directory.

  Replay treats a missing file as empty, truncates (and fsyncs) an
  unacknowledged trailing fragment that was never newline-terminated —
  the append+fsync-before-ack barrier guarantees a crash can only tear
  the tail — and re-runs every complete line through the caller-supplied
  `validator`, not JSON-decode success alone, so a byte-rotted or
  tampered record that still happens to decode as JSON is treated as
  interior corruption exactly like one that doesn't parse. Replay never
  skips forward past the first invalid line.

  Rejects a symlinked canonical directory or file rather than following
  a potentially attacker-controlled link outside the selected state
  root.
  """

  alias Aiur.Fs

  @type corruption :: {:corrupt, pos_integer(), term()}

  @doc """
  Ensures `dir` exists as an owner-only (`0700`) directory, rejecting a
  symlink at that path. Syncs the filesystem once, only when `dir` is
  created here for the first time.
  """
  @spec ensure_directory(Path.t()) :: :ok | {:error, term()}
  def ensure_directory(dir) when is_binary(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:symlink_rejected, dir}}

      {:ok, %File.Stat{type: :directory}} ->
        File.chmod(dir, 0o700)

      {:ok, %File.Stat{}} ->
        {:error, {:not_a_directory, dir}}

      {:error, :enoent} ->
        create_directory(dir)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_directory(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700) do
      Fs.sync_filesystem()
    end
  end

  @doc """
  Appends `event` (a JSON-encodable map) as one newline-terminated
  record to `path`, fsyncing the descriptor before returning. The first
  time `path` itself is created, also syncs the filesystem once so the
  new directory entry is durable.
  """
  @spec append(Path.t(), map()) :: :ok | {:error, term()}
  def append(path, event) when is_binary(path) and is_map(event) do
    with :ok <- reject_symlink(path) do
      line = Jason.encode!(event) <> "\n"
      existed_before? = File.exists?(path)

      with {:ok, fd} <- :file.open(path, [:append, :binary, :raw]) do
        try do
          with :ok <- :file.write(fd, line) do
            case :file.sync(fd) do
              :ok -> after_first_create(path, existed_before?)
              {:error, reason} -> {:error, reason}
            end
          end
        after
          :file.close(fd)
        end
      end
    end
  end

  defp after_first_create(_path, true), do: :ok

  defp after_first_create(path, false) do
    _ = File.chmod(path, 0o600)
    Fs.sync_filesystem()
  end

  @doc """
  Replays `path`: returns the validated prefix of decoded records — via
  `validator`, a `(map() -> {:ok, term()} | {:error, term()})` function —
  and `nil` corruption when the whole stream is intact, or the
  validated prefix plus `{:corrupt, line_number, reason}` at the first
  invalid complete line. A missing file replays as an empty, intact
  stream.
  """
  @spec replay(Path.t(), (map() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()], corruption() | nil} | {:error, term()}
  def replay(path, validator) when is_binary(path) and is_function(validator, 1) do
    with :ok <- reject_symlink(path),
         {:ok, content} <- read_or_empty(path) do
      {clean_content, truncated?} = drop_incomplete_tail(content)

      if truncated? do
        case truncate_and_sync(path, byte_size(clean_content)) do
          :ok -> decode_lines(clean_content, validator)
          {:error, reason} -> {:error, reason}
        end
      else
        decode_lines(clean_content, validator)
      end
    end
  end

  defp reject_symlink(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlink_rejected, path}}
      _other -> :ok
    end
  end

  defp read_or_empty(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop_incomplete_tail(""), do: {"", false}

  defp drop_incomplete_tail(content) do
    if String.ends_with?(content, "\n") do
      {content, false}
    else
      case content |> :binary.matches("\n") |> List.last() do
        nil -> {"", true}
        {index, _length} -> {binary_part(content, 0, index + 1), true}
      end
    end
  end

  # Truncates in place via ftruncate at `target_size` rather than
  # rewriting the file's leading bytes — a crash mid-rewrite would risk
  # the already-durable prefix, not just the incomplete tail.
  defp truncate_and_sync(path, target_size) do
    with {:ok, fd} <- :file.open(path, [:read, :write, :binary, :raw]) do
      try do
        with {:ok, ^target_size} <- :file.position(fd, target_size),
             :ok <- :file.truncate(fd) do
          :file.sync(fd)
        end
      after
        :file.close(fd)
      end
    end
  end

  defp decode_lines(content, validator) do
    content
    |> String.split("\n", trim: true)
    |> decode_lines(validator, 1, [])
  end

  defp decode_lines([], _validator, _line_number, acc), do: {:ok, Enum.reverse(acc), nil}

  defp decode_lines([line | rest], validator, line_number, acc) do
    with {:ok, decoded} <- Jason.decode(line),
         {:ok, validated} <- validator.(decoded) do
      decode_lines(rest, validator, line_number + 1, [validated | acc])
    else
      {:error, reason} -> {:ok, Enum.reverse(acc), {:corrupt, line_number, reason}}
    end
  end
end
