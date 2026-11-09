defmodule Aiur.Commands.CorrectiveTicketBody do
  @moduledoc false

  alias Aiur.Decision

  @spec marker(String.t()) :: String.t()
  def marker(id), do: "<!-- aiur-command-override:#{id} -->"

  @spec build(Decision.t(), map(), map(), list()) :: map()
  def build(decision, record, pr, labels) do
    revision = Enum.find(decision.revisions, &(&1.action_id == record.action_id))
    old = Decision.answer_for_action(decision, revision.prior_action_id)

    %{
      title: "Override for ##{decision.ticket.identifier}: #{decision.short_label || String.slice(decision.question, 0, 40)}",
      body: body(decision, revision, old, pr),
      labels: labels(labels)
    }
  end

  @spec labels([String.t()]) :: [String.t()]
  def labels(original) do
    copied = Enum.filter(original, &String.starts_with?(&1, ["feature:", "area:", "priority:"]))
    complexity = if "complexity:1" in original, do: "complexity:1", else: "complexity:2"
    Enum.uniq(copied ++ ["agent:todo", complexity])
  end

  defp body(decision, revision, old, pr) do
    """
    #{marker(revision.action_id)}

    Original Command: #{decision.decision_id}
    Original ticket: ##{decision.ticket.identifier}
    Question: #{decision.question}

    Old answer: #{answer(decision, old)}
    New answer: #{answer(decision, revision.answer)}

    #{pr_context(pr)}
    Override id: #{revision.action_id}

    #{instruction(pr)}
    """
    |> String.trim()
  end

  defp instruction(%{merged?: false}), do: "Apply the new answer through a new PR."
  defp instruction(_pr), do: "Change the merged behaviour to match the new answer through a new PR."

  defp pr_context(%{merged?: false} = pr), do: "Supersedes unmerged PR: ##{pr.number}. The old branch cannot be continued."
  defp pr_context(pr), do: "Merged PR: ##{pr.number}\nMerge SHA: #{pr.merge_commit_sha}"

  defp answer(_decision, nil), do: "Unavailable"
  defp answer(_decision, %{custom_response: response}) when is_binary(response), do: response

  defp answer(decision, %{selected_option_id: id}) do
    case Enum.find(decision.options, &(&1.id == id)) do
      nil -> id
      option -> "#{id}: #{option.label}"
    end
  end
end
