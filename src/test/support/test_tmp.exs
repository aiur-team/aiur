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
    ExUnit.after_suite(fn _result -> File.rm_rf!(root) end)
    root
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
