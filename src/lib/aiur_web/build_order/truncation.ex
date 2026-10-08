defmodule AiurWeb.BuildOrder.Truncation do
  @moduledoc "Explicit coverage for GitHub's bounded member preview."

  @spec notice(term()) :: String.t() | nil
  def notice(%{github_member_count: total, member_read_count: read}) when is_integer(total) and is_integer(read) and total > read,
    do: "GitHub graph truncated: #{read} of #{total} members read in the catalog preview. The selected GitHub read is bounded; a local planning pack supplies its full membership when available."

  def notice(_root), do: nil
end
