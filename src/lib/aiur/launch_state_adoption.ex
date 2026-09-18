defmodule Aiur.LaunchStateAdoption do
  @moduledoc """
  One-time adoption of state that older builds wrote to the per-launch log
  directory (#2722).

  The launcher gives every daemon launch a new log directory,
  `<logs-parent>/<launch>/log`, where `<launch>` is `<YYYYMMDDTHHMMSSZ>-<pid>`.
  Stores that must survive a restart now live in
  `Aiur.Config.Paths.runtime_state_dir/0`. When such a store is first used on
  an upgraded daemon, it copies its newest per-launch file (or file set) into
  the durable location. A marker (the durable file itself, or a marker file for
  a set) records that adoption ran, so no later launch adopts again and a file
  that a store deletes on purpose is never brought back from an old launch.

  Only sibling directories that match the launcher's launch-name pattern are
  scanned. Any other layout (a custom `--logs-root`, a test root) has no sibling
  launches, and only the current log directory is checked. That keeps adoption
  from copying state out of an unrelated directory that happens to be a
  neighbour.

  Adoption is best-effort: a failure is logged and the store starts from what
  is already in the durable location.
  """

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.Fs

  @launch_dir_pattern ~r/\A\d{8}T\d{6}Z-\d+\z/

  @doc """
  Every log directory that can hold a legacy per-launch file for this daemon:
  the current one, plus each earlier launch beside it when the current log
  directory has the launcher layout.
  """
  @spec legacy_log_dirs() :: [Path.t()]
  def legacy_log_dirs do
    log_dir = Paths.log_root_dir()
    [log_dir | sibling_launch_log_dirs(log_dir)] |> Enum.uniq()
  end

  @doc """
  Every existing legacy file named `basename` across `legacy_log_dirs/0`.
  """
  @spec legacy_files(String.t()) :: [Path.t()]
  def legacy_files(basename) when is_binary(basename) do
    legacy_log_dirs()
    |> Enum.map(&Path.join(&1, basename))
    |> Enum.filter(&File.regular?/1)
  end

  @doc """
  Copies the newest legacy `basename` file to `dest` once, when `dest` does not
  exist yet.

  Options:

    * `:companions` - suffixes of sibling files that travel with the adopted
      file (for example a marker named `<basename><suffix>`). A companion is
      copied only from the directory the adopted file came from.
    * `:empty` - content written to `dest` when no legacy file exists, so the
      durable file exists and the directory scan does not run again. When
      omitted, nothing is written and adoption is re-checked on the next call.
  """
  @spec adopt_file_once(Path.t(), String.t(), keyword()) :: :ok
  def adopt_file_once(dest, basename, opts \\ []) when is_binary(dest) and is_binary(basename) do
    unless File.exists?(dest) do
      :global.trans({{__MODULE__, :file, dest}, self()}, fn -> adopt_file(dest, basename, opts) end)
    end

    :ok
  rescue
    error ->
      Logger.warning("Could not adopt legacy #{basename} into #{dest}: #{Exception.message(error)}")
      :ok
  end

  @doc """
  Copies a per-launch file set into `dest_dir` once.

  `match?` selects the file names that belong to the set. The set is taken
  from the newest launch that holds any matching file, because that launch
  is the state the daemon had when it last stopped: a file that launch had
  already deleted is not brought back from an older launch. A file that
  already exists in `dest_dir` is never overwritten. After the copy, the
  marker file `marker` in `dest_dir` records that adoption is done.
  """
  @spec adopt_set_once(Path.t(), String.t(), (String.t() -> boolean())) :: :ok
  def adopt_set_once(dest_dir, marker, match?) when is_binary(dest_dir) and is_binary(marker) and is_function(match?, 1) do
    marker_path = Path.join(dest_dir, marker)

    unless File.exists?(marker_path) do
      :global.trans({{__MODULE__, :set, marker_path}, self()}, fn -> adopt_set(dest_dir, marker_path, match?) end)
    end

    :ok
  rescue
    error ->
      Logger.warning("Could not adopt legacy files into #{dest_dir}: #{Exception.message(error)}")
      :ok
  end

  # Re-checked under the lock: a concurrent caller may have adopted already, and
  # overwriting its newer writes with the legacy file would lose them.
  defp adopt_file(dest, basename, opts) do
    if File.exists?(dest), do: :ok, else: adopt_missing_file(dest, basename, opts)
  end

  defp adopt_missing_file(dest, basename, opts) do
    case {newest(legacy_files(basename)), Keyword.get(opts, :empty)} do
      {nil, nil} -> :ok
      {nil, empty} -> copy_bytes(empty, dest)
      {source, _empty} -> copy_adopted_file(source, dest, opts)
    end
  end

  defp copy_adopted_file(source, dest, opts) do
    for suffix <- Keyword.get(opts, :companions, []) do
      companion = source <> suffix
      if File.regular?(companion) and not File.exists?(dest <> suffix), do: copy_file(companion, dest <> suffix)
    end

    # The adopted file goes last: it is the adoption marker, so it must not
    # exist until its companions are in place.
    copy_file(source, dest)
    Logger.info("Adopted legacy per-launch state #{source} into #{dest}")
  end

  defp adopt_set(dest_dir, marker_path, match?) do
    if File.exists?(marker_path) do
      :ok
    else
      copied = copy_newest_set(dest_dir, match?)
      copy_bytes("adopted #{copied} file(s)\n", marker_path)

      if copied > 0, do: Logger.info("Adopted #{copied} legacy per-launch file(s) into #{dest_dir}")
    end
  end

  defp copy_newest_set(dest_dir, match?) do
    case newest_launch_set(match?) do
      nil ->
        0

      {dir, names} ->
        Enum.count(names, &copy_unless_present(Path.join(dir, &1), Path.join(dest_dir, &1)))
    end
  end

  defp copy_unless_present(source, dest) do
    if File.exists?(dest) do
      false
    else
      copy_file(source, dest)
      true
    end
  end

  defp newest_launch_set(match?) do
    legacy_log_dirs()
    |> Enum.flat_map(fn dir ->
      names = matching_names(dir, match?)

      case names |> Enum.map(&mtime(Path.join(dir, &1))) |> Enum.reject(&is_nil/1) do
        [] -> []
        mtimes -> [{Enum.max(mtimes), dir, names}]
      end
    end)
    |> Enum.max_by(fn {mtime, dir, _names} -> {mtime, dir} end, fn -> nil end)
    |> case do
      nil -> nil
      {_mtime, dir, names} -> {dir, names}
    end
  end

  defp matching_names(dir, match?) do
    case File.ls(dir) do
      {:ok, names} -> Enum.filter(names, &(match?.(&1) and File.regular?(Path.join(dir, &1))))
      {:error, _reason} -> []
    end
  end

  defp newest(paths) do
    paths
    |> Enum.flat_map(fn path ->
      case mtime(path) do
        nil -> []
        mtime -> [{mtime, path}]
      end
    end)
    |> Enum.max(fn -> nil end)
    |> case do
      {_mtime, path} -> path
      nil -> nil
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} -> mtime
      _missing -> nil
    end
  end

  defp copy_file(source, dest), do: copy_bytes(File.read!(source), dest)

  defp copy_bytes(bytes, dest) do
    File.mkdir_p!(Path.dirname(dest))
    :ok = Fs.atomic_write(dest, bytes, fsync: true)
  end

  defp sibling_launch_log_dirs(log_dir) do
    launch_dir = Path.dirname(log_dir)

    if Path.basename(log_dir) == "log" and Regex.match?(@launch_dir_pattern, Path.basename(launch_dir)) do
      logs_parent = Path.dirname(launch_dir)

      case File.ls(logs_parent) do
        {:ok, launches} ->
          launches
          |> Enum.filter(&Regex.match?(@launch_dir_pattern, &1))
          |> Enum.sort()
          |> Enum.map(&Path.join([logs_parent, &1, "log"]))
          |> Enum.filter(&File.dir?/1)

        {:error, _reason} ->
          []
      end
    else
      []
    end
  end
end
