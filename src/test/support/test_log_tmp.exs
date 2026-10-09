defmodule Aiur.TestLogTmp do
  @moduledoc false

  # Config runs before compilation/app boot, so this cannot depend on app modules.
  def sweep!(base, owner, alive? \\ &alive?/1) do
    for name <- File.ls!(base),
        [_, pid] <- [Regex.run(~r/^aiur-test-logs-\d+-(\d+)$/, name)] do
      path = Path.join(base, name)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory, uid: ^owner}} ->
          unless alive?.(pid), do: File.rm_rf!(path)

        {:ok, _} ->
          :ok

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          raise File.Error, reason: reason, action: "stat", path: path
      end
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
