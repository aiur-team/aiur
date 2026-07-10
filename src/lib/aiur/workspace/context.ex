defmodule Aiur.Workspace.Context do
  @moduledoc "Pure policy normalizing an issue-or-identifier into the workspace issue-context map: pr- leaf naming, todo-dispatch classification, log formatting."

  alias Aiur.TicketBranch

  @spec todo_dispatch?(map()) :: boolean()
  def todo_dispatch?(%{issue_state: issue_state, issue_labels: labels}) do
    normalize_issue_state(issue_state) == "todo" or
      Enum.any?(labels, &(normalize_issue_state(&1) == "agent:todo"))
  end

  @spec worker_host_for_log(String.t() | nil) :: String.t()
  def worker_host_for_log(nil), do: "local"
  def worker_host_for_log(worker_host), do: worker_host

  @spec build(map() | String.t() | nil) :: map()
  def build(%{id: issue_id, identifier: identifier} = issue) do
    pr_head_ref = pr_head_ref_from(issue)
    issue_identifier = identifier || "issue"

    %{
      issue_id: issue_id,
      # PR-anchored units take a `pr-<pr#>` workspace leaf (distinct from the
      # legacy `<id>` leaf), so a watched human PR never collides with a tracker
      # ticket of the same number. The running-entry identifier stays `<pr#>`
      # (the comment topic / resume key) — only the on-disk leaf is prefixed.
      issue_identifier: workspace_identifier(issue_identifier, pr_head_ref),
      issue_state: Map.get(issue, :state),
      issue_labels: Map.get(issue, :labels, []),
      pr_head_ref: pr_head_ref,
      branch_name: pr_head_ref || TicketBranch.branch_name(issue_identifier, Map.get(issue, :title))
    }
  end

  def build(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      issue_state: nil,
      issue_labels: [],
      pr_head_ref: nil,
      branch_name: TicketBranch.legacy_branch_name(identifier)
    }
  end

  def build(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      issue_state: nil,
      issue_labels: [],
      pr_head_ref: nil,
      branch_name: TicketBranch.legacy_branch_name("issue")
    }
  end

  @spec log_context(map()) :: String.t()
  def log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end

  # The PR-anchored head ref the dispatch path stamps on a synthetic PR work
  # unit (`%{pr_head_ref: "<branch>"}`). Only a non-empty binary marks a unit
  # as PR-anchored; everything else (legacy `aiur/<id>` tickets, bare
  # identifiers) returns nil and keeps the unchanged branch behavior.
  defp pr_head_ref_from(issue) when is_map(issue) do
    case Map.get(issue, :pr_head_ref) do
      ref when is_binary(ref) and ref != "" -> ref
      _ -> nil
    end
  end

  defp workspace_identifier(identifier, pr_head_ref) when is_binary(pr_head_ref),
    do: "pr-" <> identifier

  defp workspace_identifier(identifier, _pr_head_ref), do: identifier

  defp normalize_issue_state(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_issue_state(_value), do: ""
end
