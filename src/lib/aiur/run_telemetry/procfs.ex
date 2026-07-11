defmodule Aiur.RunTelemetry.Procfs do
  @moduledoc """
  Fail-open Linux procfs reader used by run telemetry.

  Process discovery reads the proc root once and parses only `stat` for the
  parent graph. Detailed status, I/O, and descriptor reads are limited to the
  actor PIDs selected by the sampler.
  """

  @kilobyte 1_024

  @type process :: %{
          pid: pos_integer(),
          ppid: non_neg_integer(),
          cpu_ticks: non_neg_integer(),
          start_time_ticks: non_neg_integer()
        }

  @type warning :: %{pid: pos_integer() | nil, field: atom(), reason: term()}

  @doc "Builds the minimal process table needed for tree attribution."
  @spec process_table(keyword()) ::
          {:ok, %{optional(pos_integer()) => process()}, [warning()]}
          | {:error, {:procfs_unavailable, term()}}
  def process_table(opts \\ []) do
    root = Keyword.get(opts, :root, "/proc")

    case File.ls(root) do
      {:ok, entries} ->
        {table, warnings} = read_processes(root, entries)
        {:ok, table, warnings}

      {:error, reason} ->
        {:error, {:procfs_unavailable, reason}}
    end
  rescue
    error -> {:error, {:procfs_unavailable, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:procfs_unavailable, {kind, reason}}}
  end

  @doc "Reads detailed counters for the already-attributed PIDs."
  @spec measure_many(map(), MapSet.t(pos_integer()), keyword()) ::
          {:ok, %{optional(pos_integer()) => map()}, [warning()]}
  def measure_many(table, pids, opts \\ []) when is_map(table) do
    root = Keyword.get(opts, :root, "/proc")

    {measured, warnings} =
      Enum.reduce(pids, {%{}, []}, fn pid, {measured, warnings} ->
        case Map.get(table, pid) do
          nil ->
            {measured, [warning(pid, :stat, :missing_from_process_table) | warnings]}

          base ->
            {process, process_warnings} = measure_process(root, base)
            {Map.put(measured, pid, process), process_warnings ++ warnings}
        end
      end)

    {:ok, measured, Enum.reverse(warnings)}
  rescue
    error -> {:ok, %{}, [warning(nil, :procfs, Exception.message(error))]}
  catch
    kind, reason -> {:ok, %{}, [warning(nil, :procfs, {kind, reason})]}
  end

  @doc false
  @spec parse_stat(binary()) :: {:ok, process()} | {:error, :malformed_stat}
  def parse_stat(contents) when is_binary(contents) do
    line = String.trim(contents)

    with [{close_index, 2} | _] <- line |> :binary.matches(") ") |> Enum.reverse(),
         [pid_token, _rest] <- String.split(line, " ", parts: 2),
         {:ok, pid} <- parse_non_negative(pid_token),
         fields <- line |> binary_part(close_index + 2, byte_size(line) - close_index - 2) |> String.split(),
         {:ok, ppid} <- integer_field(fields, 1),
         {:ok, utime} <- integer_field(fields, 11),
         {:ok, stime} <- integer_field(fields, 12),
         {:ok, start_time} <- integer_field(fields, 19),
         true <- pid > 0 do
      {:ok,
       %{
         pid: pid,
         ppid: ppid,
         cpu_ticks: utime + stime,
         start_time_ticks: start_time
       }}
    else
      _other -> {:error, :malformed_stat}
    end
  end

  def parse_stat(_contents), do: {:error, :malformed_stat}

  @doc false
  @spec parse_rss_bytes(binary()) :: {:ok, non_neg_integer()} | {:error, :unavailable}
  def parse_rss_bytes(contents) when is_binary(contents) do
    case Regex.run(~r/^VmRSS:\s+(\d+)\s+kB\s*$/m, contents, capture: :all_but_first) do
      [kilobytes] -> parse_scaled(kilobytes, @kilobyte)
      _other -> {:error, :unavailable}
    end
  end

  def parse_rss_bytes(_contents), do: {:error, :unavailable}

  @doc false
  @spec parse_io(binary()) ::
          {:ok, %{read_bytes: non_neg_integer(), write_bytes: non_neg_integer()}}
          | {:error, :unavailable}
  def parse_io(contents) when is_binary(contents) do
    values =
      contents
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] when key in ["read_bytes", "write_bytes"] ->
            case parse_non_negative(String.trim(value)) do
              {:ok, parsed} -> Map.put(acc, String.to_existing_atom(key), parsed)
              _error -> acc
            end

          _other ->
            acc
        end
      end)

    case values do
      %{read_bytes: read_bytes, write_bytes: write_bytes} ->
        {:ok, %{read_bytes: read_bytes, write_bytes: write_bytes}}

      _other ->
        {:error, :unavailable}
    end
  end

  def parse_io(_contents), do: {:error, :unavailable}

  @doc false
  @spec clock_ticks_per_second(keyword()) :: pos_integer() | :unavailable
  def clock_ticks_per_second(opts \\ []) do
    command = Keyword.get(opts, :command, fn -> System.cmd("getconf", ["CLK_TCK"], stderr_to_stdout: true) end)

    case command.() do
      {output, 0} ->
        case parse_non_negative(String.trim(output)) do
          {:ok, ticks} when ticks > 0 -> ticks
          _other -> :unavailable
        end

      _other ->
        :unavailable
    end
  rescue
    _error -> :unavailable
  end

  defp read_processes(root, entries) do
    entries
    |> numeric_pids()
    |> Enum.reduce({%{}, []}, fn pid, {table, warnings} ->
      case File.read(proc_path(root, pid, "stat")) do
        {:ok, contents} ->
          case parse_stat(contents) do
            {:ok, %{pid: ^pid} = process} -> {Map.put(table, pid, process), warnings}
            {:ok, _other_pid} -> {table, [warning(pid, :stat, :pid_mismatch) | warnings]}
            {:error, reason} -> {table, [warning(pid, :stat, reason) | warnings]}
          end

        {:error, reason} ->
          {table, [warning(pid, :stat, reason) | warnings]}
      end
    end)
    |> then(fn {table, warnings} -> {table, Enum.reverse(warnings)} end)
  end

  defp measure_process(root, base) do
    case verify_identity(root, base) do
      {:ok, current} -> read_detailed_fields(root, current)
      {:error, reason} -> {empty_measurement(base), [warning(base.pid, :stat, reason)]}
    end
  end

  defp verify_identity(root, base) do
    with {:ok, contents} <- File.read(proc_path(root, base.pid, "stat")),
         {:ok, current} <- parse_stat(contents),
         true <- current.start_time_ticks == base.start_time_ticks do
      {:ok, current}
    else
      false -> {:error, :pid_reused}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unavailable}
    end
  end

  defp read_detailed_fields(root, base) do
    {rss_bytes, rss_warning} = read_rss(root, base.pid)
    {io, io_warning} = read_io(root, base.pid)
    {fd_count, fd_warning} = read_fd_count(root, base.pid)

    process =
      Map.merge(base, %{
        rss_bytes: rss_bytes,
        read_bytes: io && io.read_bytes,
        write_bytes: io && io.write_bytes,
        fd_count: fd_count
      })

    warnings = Enum.reject([rss_warning, io_warning, fd_warning], &is_nil/1)
    {process, warnings}
  end

  defp empty_measurement(base) do
    Map.merge(base, %{rss_bytes: nil, read_bytes: nil, write_bytes: nil, fd_count: nil})
  end

  defp read_rss(root, pid) do
    with {:ok, contents} <- File.read(proc_path(root, pid, "status")),
         {:ok, bytes} <- parse_rss_bytes(contents) do
      {bytes, nil}
    else
      {:error, reason} -> {nil, warning(pid, :rss, reason)}
    end
  end

  defp read_io(root, pid) do
    with {:ok, contents} <- File.read(proc_path(root, pid, "io")),
         {:ok, io} <- parse_io(contents) do
      {io, nil}
    else
      {:error, reason} -> {nil, warning(pid, :io, reason)}
    end
  end

  defp read_fd_count(root, pid) do
    case File.ls(proc_path(root, pid, "fd")) do
      {:ok, entries} -> {entries |> numeric_pids() |> length(), nil}
      {:error, reason} -> {nil, warning(pid, :fd, reason)}
    end
  end

  defp numeric_pids(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      case parse_non_negative(entry) do
        {:ok, pid} -> [pid]
        _error -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp integer_field(fields, index) do
    fields
    |> Enum.at(index)
    |> parse_non_negative()
  end

  defp parse_scaled(value, scale) do
    case parse_non_negative(value) do
      {:ok, parsed} -> {:ok, parsed * scale}
      _error -> {:error, :unavailable}
    end
  end

  defp parse_non_negative(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _other -> {:error, :unavailable}
    end
  end

  defp parse_non_negative(_value), do: {:error, :unavailable}

  defp proc_path(root, pid, file), do: Path.join([root, Integer.to_string(pid), file])
  defp warning(pid, field, reason), do: %{pid: pid, field: field, reason: reason}
end
