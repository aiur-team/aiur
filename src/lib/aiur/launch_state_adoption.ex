defmodule Aiur.LaunchStateAdoption do
  @moduledoc """
  Legacy launch file discovery and one-time project alert-ledger adoption.

  Scans the current log directory and launcher-shaped siblings across all
  instances. Event counters take their maximum for uniqueness; alert ledgers
  must use the exact project-specific filename, including its identity hash.
  Session handles and subscriptions are never adopted.

  The durable ledger file marks adoption complete. Its backfill companions
  are copied first. Failures are logged and retried on the next access.
  """

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.Fs

  @launch_dir_pattern ~r/\A\d{8}T\d{6}Z-\d+\z/

  @doc """
  Current and launcher-shaped sibling log directories, across all instances.
  No ownership inference is needed when taking a maximum counter value.
  """
  @spec legacy_log_dirs() :: [Path.t()]
  def legacy_log_dirs do
    log_dir = Paths.log_root_dir()

    [log_dir | sibling_launch_log_dirs(log_dir)]
    |> Enum.uniq()
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
