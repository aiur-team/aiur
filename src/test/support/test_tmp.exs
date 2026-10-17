defmodule Aiur.TestTmp do
  @moduledoc false

  def start!(base) do
    File.mkdir_p!(base)
    {uid, 0} = System.cmd("id", ["-u"])
    owner = uid |> String.trim() |> String.to_integer()
    %File.Stat{type: :directory, uid: ^owner} = File.lstat!(base)
    sweep!(base, owner)
    root = Path.join(base, "run-#{System.os_time(:millisecond)}-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    ExUnit.after_suite(fn _result -> remove_run_root(root) end)
    root
  end

  @doc """
  Removes the run root at suite end without ever failing the suite.

  The application and any OS child a test spawned are still alive here, so a
  late write can land mid-removal and the final `rmdir` fails with ENOTEMPTY,
  rendered "file already exists" (#4866). Retry briefly, then warn with the
  files left behind (naming the writer) and leave the directory: the next
  run's `sweep!/2` removes it once this VM's pid is dead.
  """
  def remove_run_root(root, rm \\ &File.rm_rf/1, attempts \\ 20) do
    case rm.(root) do
      {:ok, _removed} ->
        :ok

      {:error, _reason, _file} when attempts > 1 ->
        Process.sleep(50)
        remove_run_root(root, rm, attempts - 1)

      {:error, reason, file} ->
        left = root |> Path.join("**") |> Path.wildcard(match_dot: true) |> Enum.reject(&File.dir?/1)

        IO.puts(
          :stderr,
          "warning: left test run root #{root} for the next run's sweep: #{inspect(reason)} at #{file}; " <>
            "a late writer is still putting back: #{inspect(left)}"
        )
    end
  end

  def sweep!(base, owner) do
    for name <- File.ls!(base) do
      case Regex.run(~r/^(?:run-\d+|workflow)-(\d+)-\d+$/, name) do
        [_, pid] -> remove_dead_run!(Path.join(base, name), owner, String.to_integer(pid))
        nil -> :ok
      end
    end
  end

  defp remove_dead_run!(path, owner, pid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, uid: ^owner}} ->
        unless Aiur.ProcessIdentity.alive?(pid), do: File.rm_rf!(path)

      {:ok, _stat} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "stat", path: path
    end
  end
end
