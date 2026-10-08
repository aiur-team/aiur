defmodule Aiur.TestTmp do
  @moduledoc false
  @max_age_seconds 6 * 60 * 60

  def start!(base) do
    File.mkdir_p!(base)
    {uid, 0} = System.cmd("id", ["-u"])
    owner = uid |> String.trim() |> String.to_integer()
    %File.Stat{type: :directory, uid: ^owner} = File.lstat!(base)
    sweep!(base, owner, System.os_time(:second))
    root = Path.join(base, "run-#{System.os_time(:millisecond)}-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    ExUnit.after_suite(fn _result -> File.rm_rf!(root) end)
    root
  end

  def sweep!(base, owner, now) do
    for name <- File.ls!(base), Regex.match?(~r/^(run-\d+-\d+-\d+|workflow-\d+-\d+)$/, name) do
      path = Path.join(base, name)

      case File.lstat(path, time: :posix) do
        {:ok, %File.Stat{type: :directory, uid: ^owner, mtime: mtime}} when mtime < now - @max_age_seconds -> File.rm_rf!(path)
        {:ok, _stat} -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> raise File.Error, reason: reason, action: "stat", path: path
      end
    end
  end
end
