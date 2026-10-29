defmodule Aiur.TestLogTmp do
  @moduledoc false

  @spec test_root(Path.t(), integer(), String.t()) :: Path.t()
  def test_root(base, timestamp, pid) do
    Path.join(base, "aiur-test-logs-#{timestamp}-#{pid}-#{System.unique_integer([:positive])}")
  end

  # Config runs before compilation/app boot, so this cannot depend on app modules.
  def sweep!(base, owner, alive? \\ &alive?/1) do
    for name <- File.ls!(base),
        [_, pid] <- [Regex.run(~r/^aiur-test-logs-\d+-(\d+)(?:-\d+)?$/, name)] do
      remove_dead_run!(Path.join(base, name), owner, pid, alive?)
    end
  end

  defp remove_dead_run!(path, owner, pid, alive?) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, uid: ^owner}} ->
        # Build-gate hook snapshots under a run's tmp dir are read-only.
        unless alive?.(pid), do: System.cmd("chmod", ["-R", "u+w", path], stderr_to_stdout: true) && File.rm_rf!(path)

      {:ok, _} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "stat", path: path
    end
  end

  defp alive?(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true, env: [{"LC_ALL", "C"}]) do
      {output, 1} -> not String.contains?(output, "No such process")
      _ -> true
    end
  rescue
    _ -> true
  end
end
