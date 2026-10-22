defmodule VoiceConverse.TranscriptStore do
  @moduledoc """
  Append-only NDJSON transcript, one file per conversation: `<transcript_root>/<conversation_id>.ndjson`.

  Every record is one newline-terminated line `{"v":1,"type":…,"at":iso8601,…}` (voice-session
  contract §9). `append/2` writes through the raw fd held by the writer and datasyncs it before
  returning, so a caller that emits a client event after `:ok` never announces a record a crash
  can lose ("persist before notify"). The root directory (0700) and the file (0600) are created at
  `open/4`, followed by one filesystem barrier so the new directory entries survive a crash too.

  The append-then-sync barrier means a crash can only tear the final line. `read/2` reports and
  skips such a tail (`torn_tail: true`) and leaves the file untouched: transcripts are review
  material, so bytes are never deleted. An invalid line before the last one is interior
  corruption and fails the read.

  `conversation_id` must match `vc_` plus 22 URL-safe characters, which refuses traversal by
  construction; the resolved path is also checked to stay under the root. Records that carry
  audio, keys or signed URLs (fields `audio`, `data_b64`, `signed_url`, `api_key` at any depth)
  are refused before anything is written.

  The raw fd belongs to the process that called `open/4`; only that process may `append/2`.
  """

  @version 1
  @id_regex ~r/\Avc_[A-Za-z0-9_-]{22}\z/
  @types ~w(session_started context user_turn assistant_turn tool_call tool_result draft delivery
            provider_conversation session_ended)
  @forbidden ~w(audio data_b64 signed_url api_key)

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
    record = Map.merge(session_started, %{"type" => "session_started", "conversation_id" => conversation_id})

    with {:ok, path} <- path(root, conversation_id),
         {:ok, line} <- encode(record),
         :ok <- ensure_root(root),
         {:ok, fd} <- create(path) do
      store = %__MODULE__{conversation_id: conversation_id, path: path, fd: fd, datasync: datasync}

      with :ok <- sync_fs.(), :ok <- write_line(store, line) do
        {:ok, store}
      else
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
  invalid JSON is skipped and reported as `torn_tail: true`; the file is not modified.
  """
  @spec read(Path.t(), String.t()) ::
          {:ok, [record()], %{torn_tail: boolean()}} | {:error, :not_found | {:corrupt, pos_integer()} | term()}
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

  defp encode(record) do
    record = Map.new(record, fn {k, v} -> {to_string(k), v} end)

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

  defp forbidden_field(map) when is_map(map) do
    Enum.find_value(map, fn {k, v} -> if to_string(k) in @forbidden, do: to_string(k), else: forbidden_field(v) end)
  end

  defp forbidden_field(list) when is_list(list), do: Enum.find_value(list, &forbidden_field/1)
  defp forbidden_field(_), do: nil

  defp write_line(%__MODULE__{fd: fd, datasync: datasync}, line) do
    with :ok <- :file.write(fd, line), do: datasync.(fd)
  end

  defp ensure_root(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} -> File.chmod(root, 0o700)
      {:ok, %File.Stat{}} -> {:error, {:not_a_directory, root}}
      {:error, :enoent} -> with :ok <- File.mkdir_p(root), do: File.chmod(root, 0o700)
      {:error, reason} -> {:error, reason}
    end
  end

  # :exclusive refuses an existing path, including a planted symlink.
  defp create(path) do
    case :file.open(path, [:append, :binary, :raw, :exclusive]) do
      {:ok, fd} -> with :ok <- File.chmod(path, 0o600), do: {:ok, fd}
      {:error, :eexist} -> {:error, :exists}
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

    lines
    |> Enum.with_index(1)
    |> Enum.reduce_while({[], unterminated?}, fn {line, n}, {acc, torn?} ->
      case Jason.decode(line) do
        {:ok, %{} = record} -> {:cont, {[record | acc], torn?}}
        _ when n == last and not unterminated? -> {:cont, {acc, true}}
        _ -> {:halt, {:corrupt, n}}
      end
    end)
    |> case do
      {:corrupt, n} -> {:error, {:corrupt, n}}
      {records, torn?} -> {:ok, Enum.reverse(records), %{torn_tail: torn?}}
    end
  end

  defp sync_filesystem do
    case System.cmd("sync", [], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:sync_failed, status, output}}
    end
  end
end
