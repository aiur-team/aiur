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
  Prepares the canonical directory and audit file before the store starts
  serving calls. When either entry is first created, runs one filesystem
  barrier after both exist and have owner-only permissions. This keeps the
  global barrier out of the request/append path.
  """
  @spec prepare(Path.t(), Path.t(), (-> :ok | {:error, term()})) :: :ok | {:error, term()}
  def prepare(dir, path, sync_fun \\ &Fs.sync_filesystem/0)
      when is_binary(dir) and is_binary(path) and is_function(sync_fun, 0) do
    with {:ok, directory_created?} <- ensure_directory_state(dir),
         {:ok, file_created?} <- ensure_file(path) do
      maybe_sync_creation(directory_created? or file_created?, sync_fun)
    end
  end

  @doc """
  Ensures `dir` exists as an owner-only (`0700`) directory, rejecting a
  symlink at that path. `prepare/3` owns the one-time filesystem barrier;
  this lower-level helper only creates and hardens the directory.
  """
  @spec ensure_directory(Path.t()) :: :ok | {:error, term()}
  def ensure_directory(dir) when is_binary(dir) do
    case ensure_directory_state(dir) do
      {:ok, _created?} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_directory_state(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:symlink_rejected, dir}}

      {:ok, %File.Stat{type: :directory}} ->
        with :ok <- File.chmod(dir, 0o700), do: {:ok, false}

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
      {:ok, true}
    end
  end

  defp ensure_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlink_rejected, path}}
      {:ok, %File.Stat{type: :regular}} -> with(:ok <- File.chmod(path, 0o600), do: {:ok, false})
      {:ok, %File.Stat{}} -> {:error, {:not_a_file, path}}
      {:error, :enoent} -> create_file(path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_file(path) do
    case :file.open(path, [:write, :binary, :raw, :exclusive]) do
      {:ok, fd} ->
        :ok = :file.close(fd)
        with :ok <- File.chmod(path, 0o600), do: {:ok, true}

      {:error, :eexist} ->
        ensure_file(path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_sync_creation(false, _sync_fun), do: :ok
  defp maybe_sync_creation(true, sync_fun), do: sync_fun.()

  @doc """
  Appends `event` (a JSON-encodable map) as one newline-terminated
  record to `path`, fsyncing the descriptor before returning. Production
  callers prepare the file with `prepare/3`, so this hot path never runs
  the global filesystem barrier.
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
              :ok -> harden_first_create(path, existed_before?)
              {:error, reason} -> {:error, reason}
            end
          end
        after
          :file.close(fd)
        end
      end
    end
  end

  defp harden_first_create(_path, true), do: :ok
  defp harden_first_create(path, false), do: File.chmod(path, 0o600)

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
  def replay(path, validator), do: replay(path, validator, [])

  @spec replay(Path.t(), (map() -> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, [term()], corruption() | nil} | {:error, term()}
  def replay(path, validator, opts) when is_binary(path) and is_function(validator, 1) and is_list(opts) do
    with :ok <- reject_symlink(path),
         :ok <- validate_file_size(path, Keyword.get(opts, :max_file_bytes)),
         {:ok, content} <- read_or_empty(path) do
      {clean_content, truncated?} = drop_incomplete_tail(content)
      finish_replay(path, clean_content, truncated?, validator, Keyword.get(opts, :max_record_bytes))
    end
  end

  defp finish_replay(_path, clean_content, false, validator, max_record_bytes),
    do: decode_lines(clean_content, validator, max_record_bytes)

  defp finish_replay(path, clean_content, true, validator, max_record_bytes) do
    case truncate_and_sync(path, byte_size(clean_content)) do
      :ok -> decode_lines(clean_content, validator, max_record_bytes)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_file_size(_path, nil), do: :ok

  defp validate_file_size(path, max_file_bytes) when is_integer(max_file_bytes) and max_file_bytes > 0 do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{size: size}} when size <= max_file_bytes -> :ok
      {:ok, %File.Stat{}} -> {:error, :recovery_file_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_file_size(_path, _max_file_bytes), do: {:error, :invalid_replay_limit}

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

  defp decode_lines(content, validator, max_record_bytes) do
    content
    |> String.split("\n")
    |> drop_terminal_delimiter()
    |> decode_lines(validator, max_record_bytes, 1, [])
  end

  defp drop_terminal_delimiter(lines) do
    if List.last(lines) == "", do: List.delete_at(lines, -1), else: lines
  end

  defp decode_lines([], _validator, _max_record_bytes, _line_number, acc), do: {:ok, Enum.reverse(acc), nil}

  defp decode_lines([line | rest], validator, max_record_bytes, line_number, acc) do
    with :ok <- validate_record_size(line, max_record_bytes),
         {:ok, decoded} <- Jason.decode(line),
         {:ok, validated} <- validator.(decoded) do
      decode_lines(rest, validator, max_record_bytes, line_number + 1, [validated | acc])
    else
      {:error, reason} -> {:ok, Enum.reverse(acc), {:corrupt, line_number, reason}}
    end
  end

  defp validate_record_size(_line, nil), do: :ok
  defp validate_record_size(line, max_record_bytes) when byte_size(line) <= max_record_bytes, do: :ok
  defp validate_record_size(_line, _max_record_bytes), do: {:error, :record_too_large}
end
