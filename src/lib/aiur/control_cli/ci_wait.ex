defmodule Aiur.ControlCLI.CiWait do
  @moduledoc false

  @spec print(map()) :: :ok
  def print(snapshot) do
    snapshot
    |> Map.get(:ci_wait, [])
    |> Enum.sort_by(& &1.identifier)
    |> Enum.each(fn ci ->
      failures = ci |> Map.get(:failures, []) |> Enum.map_join(", ", & &1.name)
      state = if ci[:pending_reason] == :draft_pull_request, do: "draft_pr", else: ci[:recovery] || ci[:pending_reason] || ci[:decision] || "unobserved"
      IO.puts("CI WAIT #{ci.identifier} PR ##{ci[:pr_number] || "unknown"}: #{state}#{if failures == "", do: "", else: " (#{failures})"}")
    end)
  end
end
