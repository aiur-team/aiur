defmodule Aiur.Workspace.DeletedEmptyFiles do
  @moduledoc """
  Removes untracked files that are empty and whose path the base branch deleted.

  A stray empty `streamdeck_key_face_contract.ex` (deleted on main in #7014) sat
  untracked in the warm base and was copied into every workspace, where workers
  committed it or tripped clean-tree checks (#7920). Any other untracked file is
  left alone: in a workspace it can be a worker's real work, and in the base it can
  be build output.
  """

  @type git_fun :: ([String.t()] -> {String.t(), non_neg_integer()})

  @spec remove(Path.t(), String.t(), git_fun()) :: {:ok, [Path.t()]} | {:error, term()}
  def remove(dir, ref, git) do
    case git.(["ls-files", "-z", "--others", "--exclude-standard"]) do
      {out, 0} ->
        out
        |> String.split(<<0>>, trim: true)
        |> Enum.filter(&(empty_file?(Path.join(dir, &1)) and deleted_on?(git, ref, &1)))
        |> remove_all(dir)

      {out, status} ->
        {:error, {:deleted_empty_files_list_failed, status, out}}
    end
  end

  @spec remove(Path.t(), String.t()) :: {:ok, [Path.t()]} | {:error, term()}
  def remove(dir, ref), do: remove(dir, ref, &System.cmd("git", &1, cd: dir, stderr_to_stdout: true))

  defp empty_file?(path), do: match?({:ok, %File.Stat{type: :regular, size: 0}}, File.lstat(path))

  defp deleted_on?(git, ref, path) do
    case git.(["log", ref, "--diff-filter=D", "-1", "--format=%H", "--", path]) do
      {out, 0} -> String.trim(out) != ""
      _ -> false
    end
  end

  defp remove_all(paths, dir) do
    Enum.reduce_while(paths, {:ok, paths}, fn path, acc ->
      case File.rm(Path.join(dir, path)) do
        :ok -> {:cont, acc}
        {:error, reason} -> {:halt, {:error, {:deleted_empty_file_remove_failed, path, reason}}}
      end
    end)
  end
end
