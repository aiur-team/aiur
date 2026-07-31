defmodule Aiur.RunTelemetry.Retention do
  @moduledoc false

  # Retention intentionally runs before a new Writer appends its restart marker.
  # That is the one point where no live writer owns the stream, so replacing the
  # file cannot strand buffered appends on an old inode.
  #
  # Periodic in-writer pruning (see Writer.maybe_prune/1) uses the same path so
  # old-boot pruning also occurs during long-running sessions, not only at boot.

  @spec prune(Path.t(), keyword()) :: :ok | {:error, term()}
  def prune(path, opts \\ [])

  def prune(path, opts) when is_binary(path) and is_list(opts) do
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

  def prune(_path, _opts), do: :ok

  # Streams the file line-by-line so large files are never fully loaded into RAM.
  defp read_boot_groups(path) do
    groups =
      path
      |> File.stream!(:line, [])
      |> Enum.reduce({[], []}, fn line, {groups, current} ->
        case restart_metadata(line) do
          {:ok, timestamp, boot_id} when current != [] ->
            {[new_group(current) | groups], [{line, timestamp, boot_id}]}

          {:ok, timestamp, boot_id} ->
            {groups, [{line, timestamp, boot_id}]}

          :error ->
            {groups, [{line, nil, nil} | current]}
        end
      end)
      |> then(fn {groups, current} ->
        groups = if current == [], do: groups, else: [new_group(current) | groups]
        Enum.reverse(groups)
      end)

    {:ok, groups}
  rescue
    e in File.Error -> {:error, e.reason}
    error -> {:error, inspect(error)}
  end

  defp new_group(lines) do
    lines = Enum.reverse(lines)

    %{
      contents: Enum.map(lines, &elem(&1, 0)) |> IO.iodata_to_binary(),
      started_at: Enum.find_value(lines, fn {_line, timestamp, _boot_id} -> timestamp end),
      boot_id: Enum.find_value(lines, fn {_line, _timestamp, boot_id} -> boot_id end)
    }
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

  # A single boot may legitimately be larger than the target. Keep that whole
  # boot rather than turning a valid interval stream into a partial one.
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
      Enum.reduce(Enum.reverse(groups), {[], 0}, fn group, acc ->
        retain_group(group, acc, max_bytes, protected_boot_id)
      end)

    retained
  end

  defp retain_group(group, {retained, size}, max_bytes, protected_boot_id) do
    group_size = byte_size(group.contents)

    if group.boot_id == protected_boot_id or retained == [] or size + group_size <= max_bytes do
      {[group | retained], size + group_size}
    else
      {retained, size}
    end
  end

  defp contents_for(groups), do: groups |> Enum.map(& &1.contents) |> IO.iodata_to_binary()

  defp write_retained(path, retained) do
    directory = Path.dirname(path)
    temporary = Path.join(directory, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")
    contents = contents_for(retained)

    with :ok <- File.write(temporary, contents, [:binary]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end
end
