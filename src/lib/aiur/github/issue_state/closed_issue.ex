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
         :ok <-
           IssueState.remove_active_state_labels(context.request_fun, context.token, context.owner, context.repo, context.issue_number, issue, context.prefix,
             clear_terminal_state_overrides: Keyword.get(context.opts, :clear_terminal_state_overrides, false)
           ) do
      {:error, {:no_state_label_written, terminal_issue(issue, context.prefix, context.opts)}}
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

  defp terminal_issue(issue, prefix, opts) do
    labels = names(issue)
    terminal = Enum.find(labels, &StatePolicy.terminal_state_label?(&1, prefix)) || StatePolicy.state_label(prefix, "done")

    labels =
      Enum.reject(labels, fn label ->
        String.starts_with?(label, "#{prefix}:") and
          (not IssueState.preserved_prefixed_label?(label, prefix) or
             (Keyword.get(opts, :clear_terminal_state_overrides, false) and label in ["#{prefix}:parked", "#{prefix}:paused"])) and
          not StatePolicy.terminal_state_label?(label, prefix)
      end)

    Map.put(issue, "labels", Enum.map(Enum.uniq([terminal | labels]), &%{"name" => &1}))
  end

  defp names(issue), do: Enum.map(Map.get(issue, "labels", []), &Map.get(&1, "name", ""))
end
