defmodule Aiur.GitHub.IssueState.ClosedIssue do
  @moduledoc false

  alias Aiur.GitHub.{IssueState, StatePolicy}

  @spec apply(map(), map()) :: {:error, term()}
  def apply(context, issue) do
    if Keyword.get(context.opts, :expected_state) == :none do
      {:error, {:no_state_label_written, issue}}
    else
      transition(context, issue)
    end
  end

  defp transition(context, issue) do
    with :ok <- ensure_terminal_label(context, issue),
         :ok <- IssueState.remove_active_state_labels(context.request_fun, context.token, context.owner, context.repo, context.issue_number, issue, context.prefix) do
      {:error, {:no_state_label_written, terminal_issue(issue, context.prefix)}}
    end
  end

  defp ensure_terminal_label(context, issue) do
    labels = names(issue)

    if Enum.any?(labels, &StatePolicy.terminal_state_label?(&1, context.prefix)) do
      :ok
    else
      IssueState.add_issue_label(context.request_fun, context.token, context.owner, context.repo, context.issue_number, StatePolicy.state_label(context.prefix, "done"))
    end
  end

  defp terminal_issue(issue, prefix) do
    labels = names(issue)
    terminal = Enum.find(labels, &StatePolicy.terminal_state_label?(&1, prefix)) || StatePolicy.state_label(prefix, "done")
    labels = Enum.reject(labels, &(String.starts_with?(&1, "#{prefix}:") and not IssueState.preserved_prefixed_label?(&1, prefix) and not StatePolicy.terminal_state_label?(&1, prefix)))
    Map.put(issue, "labels", Enum.map(Enum.uniq([terminal | labels]), &%{"name" => &1}))
  end

  defp names(issue), do: Enum.map(Map.get(issue, "labels", []), &Map.get(&1, "name", ""))
end
