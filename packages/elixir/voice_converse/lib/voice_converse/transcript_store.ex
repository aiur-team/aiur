defmodule VoiceConverse.TranscriptStore do
  @moduledoc """
  Append-only NDJSON transcript, one file per conversation: `<transcript_root>/<conversation_id>.ndjson`.

  Every record is one newline-terminated line `{"v":1,"type":…,"at":iso8601,…}` (voice-session
  contract §9). `append/2` writes through the raw fd held by the writer and datasyncs it before
  returning, so a caller that emits a client event after `:ok` never announces a record a crash
  can lose ("persist before notify"). `open/4` creates the file (0600), and the root (0700) if it
  is missing, followed by one filesystem barrier so the new directory entries survive a crash too.
  An existing root must already be owner-only and not a symlink; it is refused, never chmodded.

  The append-then-sync barrier means a crash can only tear the line being written. `read/2`
  reports and skips such a line and leaves the file untouched: transcripts are review material, so
  bytes are never deleted. A torn final line is `torn_tail: true`. `reopen/3` (used to append
  after a crash, e.g. a `session_ended` at boot) first terminates a torn final line with `"\n"`, so
  later records start on their own line; the torn bytes then become an interior line, which
  `read/2` skips and lists in `skipped_lines`.

  `conversation_id` must match `vc_` plus 22 URL-safe characters, which refuses traversal by
  construction; the resolved path is also checked to stay under the root. Records are refused
  before anything is written if they carry a top-level `audio` field, or `data_b64`, `signed_url`
  or `api_key` at any depth. Redacting text fields is the caller's job (plan §17.3: the session
  applies `Config.redactor` before the store).

  The raw fd belongs to the process that called `open/4` or `reopen/3`; only that process may
  `append/2`.
  """

  @version 1
  @id_regex ~r/\Avc_[A-Za-z0-9_-]{22}\z/
  @types ~w(session_started context user_turn assistant_turn tool_call tool_result draft delivery
            provider_conversation session_ended)
  @forbidden_top ~w(audio data_b64 signed_url api_key)
  @forbidden_deep ~w(data_b64 signed_url api_key)

  @enforce_keys [:conversation_id, :path, :fd, :datasync]
  defstruct @enforce_keys

  @type t :: %__MODULE__{conversation_id: String.t(), path: Path.t(), fd: term(), datasync: (term() -> term())}
  @type record :: map()

  @doc """
  Creates the conversation file under `root` and appends `session_started`. Fails with `:exists`
  if the conversation already has a transcript.

  Options (for tests): `:datasync` (`fd -> :ok | {:error, _}`, default `:file.datasync/1`) and
  `:sync_fs` (`-> :ok | {:error, _}`, the creation barrier, default `sync(1)`).
  """
  @spec open(Path.t(), String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(root, conversation_id, session_started, opts \\ []) when is_map(session_started) do
    datasync = Keyword.get(opts, :datasync, &:file.datasync/1)
    sync_fs = Keyword.get(opts, :sync_fs, &sync_filesystem/0)
    record = Map.merge(stringify(session_started), %{"type" => "session_started", "conversation_id" => conversation_id})

    with {:ok, path} <- path(root, conversation_id),
         {:ok, line} <- encode(record),
         :ok <- ensure_root(root),
         {:ok, fd} <- create(path) do
      store = %__MODULE__{conversation_id: conversation_id, path: path, fd: fd, datasync: datasync}

      with :ok <- sync_fs.(), :ok <- write_line(store, line) do
        {:ok, store}
      else
        {:error, reason} ->
          # Free the id: a file without its session_started line is not a transcript.
          :file.close(fd)
          File.rm(path)
          {:error, reason}
      end
    end
  end

  @doc """
  Opens an existing transcript for appending. If the file does not end in a newline (a torn
  final line), writes and syncs `"\n"` first. Takes the `:datasync` option of `open/4`.
  """
  @spec reopen(Path.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def reopen(root, conversation_id, opts \\ []) do
    datasync = Keyword.get(opts, :datasync, &:file.datasync/1)

    with {:ok, path} <- path(root, conversation_id),
         {:ok, size} <- regular_file_size(path),
         {:ok, fd} <- :file.open(path, [:read, :append, :binary, :raw]) do
      store = %__MODULE__{conversation_id: conversation_id, path: path, fd: fd, datasync: datasync}

      case seal_torn_tail(store, size) do
        :ok ->
          {:ok, store}

        {:error, reason} ->
          :file.close(fd)
          {:error, reason}
      end
    end
  end

  @doc "Appends one record and returns only after it is synced to disk. Nothing is written on a refusal."
  @spec append(t(), record()) :: :ok | {:error, term()}
  def append(%__MODULE__{} = store, record) when is_map(record) do
    with {:ok, line} <- encode(record), do: write_line(store, line)
  end

  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{fd: fd}), do: :file.close(fd)

  @doc """
  Reads every complete record (string keys, file order). A final line without a newline or with
  invalid JSON is skipped and reported as `torn_tail: true`; an invalid earlier line (a torn line
  sealed by `reopen/3`) is skipped and its 1-based number listed in `skipped_lines`. The file is
  not modified.
  """
  @spec read(Path.t(), String.t()) ::
          {:ok, [record()], %{torn_tail: boolean(), skipped_lines: [pos_integer()]}} | {:error, :not_found | term()}
  def read(root, conversation_id) do
    with {:ok, path} <- path(root, conversation_id),
         {:ok, content} <- read_file(path) do
      {complete, tail} = split_lines(content)
      decode_lines(complete, tail != "")
    end
  end

  @doc "The transcript path for `conversation_id`, or an error if the id or the root is unsafe."
  @spec path(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, :invalid_root | :invalid_conversation_id}
  def path(root, _id) when not is_binary(root) or root == "", do: {:error, :invalid_root}

  def path(root, id) when is_binary(id) do
    root = Path.expand(root)
    path = Path.expand(id <> ".ndjson", root)

    if Regex.match?(@id_regex, id) and Path.dirname(path) == root,
      do: {:ok, path},
      else: {:error, :invalid_conversation_id}
  end

  def path(_root, _id), do: {:error, :invalid_conversation_id}

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp encode(record) do
    record = stringify(record)

    cond do
      record["type"] not in @types -> {:error, {:unknown_type, record["type"]}}
      field = forbidden_field(record) -> {:error, {:forbidden_field, field}}
      true -> encode_line(Map.merge(%{"at" => DateTime.to_iso8601(DateTime.utc_now())}, record))
    end
  end

  defp encode_line(record) do
    case Jason.encode(Map.put(record, "v", @version)) do
      {:ok, json} -> {:ok, json <> "\n"}
      {:error, reason} -> {:error, {:unencodable, reason}}
    end
  end

  defp forbidden_field(record) do
    Enum.find(Map.keys(record), &(&1 in @forbidden_top)) || Enum.find_value(Map.values(record), &forbidden_deep/1)
  end

  # Structs (DateTime and friends) are values, not nested records.
  defp forbidden_deep(%_{}), do: nil

  defp forbidden_deep(map) when is_map(map) do
    Enum.find_value(map, fn {k, v} -> if to_string(k) in @forbidden_deep, do: to_string(k), else: forbidden_deep(v) end)
  end

  defp forbidden_deep(list) when is_list(list), do: Enum.find_value(list, &forbidden_deep/1)
  defp forbidden_deep(_), do: nil

  defp write_line(%__MODULE__{fd: fd, datasync: datasync}, line) do
    with :ok <- :file.write(fd, line), do: datasync.(fd)
  end

  defp ensure_root(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when Bitwise.band(mode, 0o077) != 0 ->
        {:error, {:insecure_root, mode}}

      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:symlink_rejected, root}}

      {:ok, %File.Stat{}} ->
        {:error, {:not_a_directory, root}}

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(root), do: File.chmod(root, 0o700)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # :exclusive refuses an existing path, including a planted symlink.
  defp create(path) do
    case :file.open(path, [:append, :binary, :raw, :exclusive]) do
      {:ok, fd} -> chmod_new_file(path, fd)
      {:error, :eexist} -> {:error, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp chmod_new_file(path, fd) do
    case File.chmod(path, 0o600) do
      :ok ->
        {:ok, fd}

      {:error, reason} ->
        :file.close(fd)
        File.rm(path)
        {:error, reason}
    end
  end

  defp regular_file_size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlink_rejected, path}}
      {:ok, %File.Stat{}} -> {:error, {:not_a_file, path}}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp seal_torn_tail(_store, 0), do: :ok

  defp seal_torn_tail(%__MODULE__{fd: fd} = store, size) do
    case :file.pread(fd, size - 1, 1) do
      {:ok, "\n"} -> :ok
      {:ok, _} -> write_line(store, "\n")
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp split_lines(content) do
    lines = String.split(content, "\n")
    {Enum.drop(lines, -1), List.last(lines)}
  end

  defp decode_lines(lines, unterminated?) do
    last = length(lines)

    {records, skipped, torn?} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], unterminated?}, fn {line, n}, {acc, skipped, torn?} ->
        case Jason.decode(line) do
          {:ok, %{} = record} -> {[record | acc], skipped, torn?}
          _ when n == last and not unterminated? -> {acc, skipped, true}
          _ -> {acc, [n | skipped], torn?}
        end
      end)

    {:ok, Enum.reverse(records), %{torn_tail: torn?, skipped_lines: Enum.reverse(skipped)}}
  end

  defp sync_filesystem do
    case System.cmd("sync", [], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:sync_failed, status, output}}
    end
  end
end
