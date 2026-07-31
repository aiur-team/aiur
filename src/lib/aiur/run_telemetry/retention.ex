defmodule Aiur.RunTelemetry.Retention do
  @moduledoc false

  require Logger

  # Retention.prune/2 rewrites the stream by atomic rename. It is safe to call
  # while the Writer is running because the Writer appends with per-call File.write
  # (no persistent handle), so no open handle crosses the rename.
  #
  # Boot-time pruning (Writer.init/1) runs before the restart marker is written.
  # Periodic in-writer pruning (Writer.maybe_prune/1) first writes a segment
  # boundary (a new restart marker) to close the current segment, then prunes
  # without protecting the current boot. This keeps the file bounded even when a
  # single boot generates data exceeding max_bytes.

  @copy_chunk_bytes 64 * 1024

  @spec prune(Path.t(), keyword()) :: :ok | {:error, term()}
  def prune(path, opts \\ [])

  def prune(path, opts) when is_binary(path) and is_list(opts) do
    # Fast path: skip the full parse when the file is already within the size
    # limit and no age-based eviction is configured.
    if skip_scan?(path, opts), do: :ok, else: do_prune(path, opts)
  end

  def prune(_path, _opts), do: :ok

  defp skip_scan?(path, opts) do
    max_bytes = Keyword.get(opts, :max_bytes)

    is_nil(Keyword.get(opts, :max_age_days)) and
      is_integer(max_bytes) and max_bytes > 0 and
      match?({:ok, %{size: size}} when size <= max_bytes, File.stat(path))
  end

  defp do_prune(path, opts) do
    with {:ok, groups} <- read_boot_groups(path),
         retained <- groups |> retain_by_age(opts) |> retain_by_size(opts) do
      if length(retained) < length(groups) do
        write_retained(path, retained)
      else
        :ok
      end
    else
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Scans line-by-line, recording byte offsets for each boot group without
  # materialising line content. Peak memory is O(group_count * metadata), not
  # O(file_size).
  defp read_boot_groups(path) do
    initial = {[], {0, nil, nil}, 0}

    {groups_acc, {grp_start, started_at, boot_id}, total_offset} =
      path
      |> File.stream!(:line, [])
      |> Enum.reduce(initial, fn line, {groups, {grp_start, started_at, boot_id}, offset} ->
        size = byte_size(line)
        next_offset = offset + size

        case restart_metadata(line) do
          {:ok, timestamp, new_boot_id} when offset > grp_start ->
            group = %{
              start_offset: grp_start,
              size: offset - grp_start,
              started_at: started_at,
              boot_id: boot_id
            }

            {[group | groups], {offset, timestamp, new_boot_id}, next_offset}

          {:ok, timestamp, new_boot_id} ->
            {groups, {offset, timestamp, new_boot_id}, next_offset}

          :error ->
            {groups, {grp_start, started_at, boot_id}, next_offset}
        end
      end)

    all_groups =
      if total_offset > grp_start do
        last = %{
          start_offset: grp_start,
          size: total_offset - grp_start,
          started_at: started_at,
          boot_id: boot_id
        }

        Enum.reverse([last | groups_acc])
      else
        Enum.reverse(groups_acc)
      end

    {:ok, all_groups}
  rescue
    e in File.Error -> {:error, e.reason}
  end

  defp restart_metadata(line) do
    with {:ok,
          %{
            "kind" => "restart",
            "attributes" => %{"event" => "daemon_restart"},
            "timestamp" => timestamp,
            "boot_id" => boot_id
          }} <-
           Jason.decode(line),
         {:ok, parsed, _offset} <- DateTime.from_iso8601(timestamp) do
      {:ok, parsed, boot_id}
    else
      _other -> :error
    end
  end

  defp retain_by_age(groups, opts) do
    case Keyword.get(opts, :max_age_days) do
      days when is_integer(days) and days > 0 ->
        now = Keyword.get(opts, :now, DateTime.utc_now())
        cutoff = DateTime.add(now, -days * 86_400, :second)
        protected_boot_id = Keyword.get(opts, :protected_boot_id)

        Enum.filter(groups, fn group ->
          group.boot_id == protected_boot_id or is_nil(group.started_at) or
            DateTime.compare(group.started_at, cutoff) != :lt
        end)

      _other ->
        groups
    end
  end

  # Retains the newest contiguous sequence of boots that fits within max_bytes.
  # Breaks at the first group that does not fit — older groups are dropped even
  # if they would individually fit, preserving a contiguous history window.
  # A single oversized boot is always kept regardless of size.
  defp retain_by_size(groups, opts) do
    case Keyword.get(opts, :max_bytes) do
      max_bytes when is_integer(max_bytes) and max_bytes > 0 ->
        retain_newest_groups(groups, max_bytes, Keyword.get(opts, :protected_boot_id))

      _other ->
        groups
    end
  end

  defp retain_newest_groups(groups, max_bytes, protected_boot_id) do
    {retained, _size} =
      Enum.reduce_while(Enum.reverse(groups), {[], 0}, fn group, {retained, size} ->
        group_size = group.size

        cond do
          group.boot_id == protected_boot_id ->
            {:cont, {[group | retained], size + group_size}}

          retained == [] or size + group_size <= max_bytes ->
            {:cont, {[group | retained], size + group_size}}

          true ->
            {:halt, {retained, size}}
        end
      end)

    retained
  end

  # Copies retained byte ranges from the source file to a temp file, then
  # atomically renames. Peak memory is O(@copy_chunk_bytes), not O(file_size).
  defp write_retained(path, retained) do
    directory = Path.dirname(path)
    temporary = Path.join(directory, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

    with {:ok, src} <- :file.open(path, [:read, :binary]) do
      outcome =
        case :file.open(temporary, [:write, :binary]) do
          {:ok, dst} ->
            result = copy_groups(src, dst, retained)
            :file.close(dst)
            result

          {:error, reason} ->
            {:error, reason}
        end

      :file.close(src)

      case outcome do
        :ok ->
          case File.rename(temporary, path) do
            :ok ->
              :ok

            {:error, reason} ->
              case File.rm(temporary) do
                :ok ->
                  :ok

                {:error, rm_reason} ->
                  Logger.warning("run_telemetry temp_file_leaked path=#{temporary} reason=#{inspect(rm_reason)}")
              end

              {:error, reason}
          end

        {:error, reason} ->
          case File.rm(temporary) do
            :ok ->
              :ok

            {:error, rm_reason} ->
              Logger.warning("run_telemetry temp_file_leaked path=#{temporary} reason=#{inspect(rm_reason)}")
          end

          {:error, reason}
      end
    end
  end

  defp copy_groups(_src, _dst, []), do: :ok

  defp copy_groups(src, dst, [%{start_offset: offset, size: size} | rest]) do
    case copy_range(src, dst, offset, size) do
      :ok -> copy_groups(src, dst, rest)
      error -> error
    end
  end

  defp copy_range(_src, _dst, _offset, 0), do: :ok

  defp copy_range(src, dst, offset, remaining) do
    chunk = min(remaining, @copy_chunk_bytes)

    case :file.pread(src, offset, chunk) do
      {:ok, data} ->
        case :file.write(dst, data) do
          :ok -> copy_range(src, dst, offset + byte_size(data), remaining - byte_size(data))
          {:error, _} = error -> error
        end

      :eof ->
        {:error, :unexpected_eof}

      {:error, _} = error ->
        error
    end
  end
end
