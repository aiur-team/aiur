defmodule Aiur.Commands.CorrectiveTicketBody do
  @moduledoc false

  alias Aiur.Decision

  @spec marker(String.t()) :: String.t()
  def marker(id), do: "<!-- aiur-command-override:#{id} -->"

  @doc false
  @spec late_answer_marker(String.t()) :: String.t()
  def late_answer_marker(id), do: "<!-- aiur-command-late-answer:#{id} -->"

  @doc false
  @spec create_late_answer(Decision.t(), Aiur.DecisionAnswer.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_late_answer(decision, answer, pr, opts) do
    with {:ok, [original]} <- call(opts, :issues, &Aiur.Tracker.fetch_issue_states_by_ids/1, [[decision.ticket.identifier]]),
         attrs <- late_answer(decision, answer, pr, original.labels),
         {:ok, raw} <- call(opts, :create, &Aiur.Tracker.create_issue/2, [attrs, [caller: "command_late_answer_create"]]) do
      {:ok, normalize_ticket(raw)}
    else
      {:ok, _missing} -> {:error, :original_ticket_missing}
      {:error, _reason} = error -> error
    end
  end

  @spec find_late_answer(Aiur.DecisionAnswer.t(), keyword()) :: term()
  def find_late_answer(answer, opts) do
    call(opts, :find, &Aiur.Tracker.find_issue/2, [late_answer_marker(answer.action_id), [caller: "command_late_answer_reconcile"]])
  end

  defp call(opts, key, default, args), do: apply(Keyword.get(opts, key, default), args)

  defp normalize_ticket(raw) do
    %{identifier: to_string(Map.get(raw, "number", Map.get(raw, :number))), title: Map.get(raw, :title, Map.get(raw, "title")), url: Map.get(raw, "url", Map.get(raw, :url))}
  end

  @doc false
  @spec late_answer(Decision.t(), Aiur.DecisionAnswer.t(), map(), [String.t()]) :: map()
  def late_answer(decision, answer, pr, labels) do
    selected =
      case answer.selected_option_id do
        nil ->
          answer.custom_response

        id ->
          case Enum.find(decision.options, &(&1.id == id)) do
            nil -> id
            option -> "#{id}: #{option.label}"
          end
      end

    %{
      title: "Late Command answer for ##{decision.ticket.identifier}: #{decision.short_label || String.slice(decision.question, 0, 40)}",
      body:
        """
        #{late_answer_marker(answer.action_id)}

        Original Command: #{decision.decision_id}
        Original ticket: ##{decision.ticket.identifier}
        Question: #{decision.question}
        Default proceeded on: #{decision.recommendation.option_id}
        Late answer: #{selected}
        Merged PR: ##{pr.number}
        Merge SHA: #{pr.merge_commit_sha}

        Change the merged behaviour to match the late answer through a new PR.
        """
        |> String.trim(),
      labels: labels(labels)
    }
  end

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
