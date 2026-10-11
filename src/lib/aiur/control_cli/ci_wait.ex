defmodule Aiur.ControlCLI.CiWait do
  @moduledoc false

  @spec print(map()) :: :ok
  def print(snapshot) do
    snapshot
    |> Map.get(:ci_wait, [])
    |> Enum.sort_by(& &1.identifier)
    |> Enum.each(fn ci ->
      failures = ci |> Map.get(:failures, []) |> Enum.map_join(", ", & &1.name)
      IO.puts("CI WAIT #{ci.identifier} PR ##{ci[:pr_number] || "unknown"}: #{ci[:recovery] || ci[:decision] || "unobserved"}#{if failures == "", do: "", else: " (#{failures})"}")
    end)
  end
end
