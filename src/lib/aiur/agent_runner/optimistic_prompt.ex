defmodule Aiur.AgentRunner.OptimisticPrompt do
  @moduledoc false

  alias Aiur.{OptimisticStart, TicketBranch}

  @spec render(map() | nil) :: String.t()
  def render(%{blockers: [_ | _] = blockers} = record) do
    """

    ## Optimistic start

    Aiur dispatched this ticket before these blocker PRs merged:
    #{Enum.map_join(blockers, "\n", &blocker_line/1)}

    For every listed SHA, run `git -C "$workspace" merge-base --is-ancestor <sha> HEAD`.
    If it is missing, fetch the listed ref from origin and merge its SHA before implementing.
    This applies to existing, cold-cloned and SSH workspaces as well as prewarmed ones.

    #{pr_base_instruction(record)}
    Open the PR as a draft. Keep it draft and do not move this ticket to `ci-wait` or `human-review`
    while any listed blocker PR is unmerged. Load `aiur-agent` and its `stub-then-fetch.md` optimistic-start guidance.

    """
  end

  def render(_record), do: ""

  defp blocker_line(blocker) do
    if safe_blocker?(blocker) do
      "- Issue ##{blocker.identifier}, PR #{pr_number(blocker)}, ref `#{blocker.ref}`, SHA `#{blocker.sha}`. " <>
        "Check: `git -C \"$workspace\" merge-base --is-ancestor #{blocker.sha} HEAD`."
    else
      unresolved_line(blocker)
    end
  end

  defp unresolved_line(%{identifier: id}) when is_binary(id) do
    if Regex.match?(~r/\A[1-9]\d*\z/, id),
      do: "- Blocker ##{id}: head unavailable; resolve it with `scripts/resolve-ticket-branch #{id}` before proceeding.",
      else: "- Blocker head unavailable; resolve it from the native dependency graph before proceeding."
  end

  defp unresolved_line(_blocker), do: "- Blocker head unavailable; resolve it from the native dependency graph before proceeding."

  defp pr_base_instruction(%{primary: id, blockers: [%{identifier: id} = blocker]}) when is_binary(id) do
    if safe_blocker?(blocker) do
      branch = String.trim_leading(blocker.ref, "refs/heads/")
      "For PR creation, use `--base #{branch}`. This overrides the integration-branch PR base rule until this blocker merges."
    else
      "Resolve the blocker head before choosing a PR base."
    end
  end

  defp pr_base_instruction(_record),
    do: "With several unmerged blockers, use `--base \"$AIUR_BASE_BRANCH\"` and integrate every listed head."

  defp safe_blocker?(%{identifier: id} = blocker),
    do: OptimisticStart.valid_head?(blocker) and TicketBranch.ticket_id_from_ref(blocker.ref) == id

  defp safe_blocker?(_blocker), do: false

  defp pr_number(%{pr_number: number}) when is_integer(number) and number > 0, do: "##{number}"
  defp pr_number(_blocker), do: "unknown"
end
