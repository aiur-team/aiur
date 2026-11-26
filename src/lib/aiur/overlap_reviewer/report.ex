defmodule Aiur.OverlapReviewer.Report do
  @moduledoc false

  alias Aiur.ExecutorSweep.Wake

  @spec verdict(pos_integer(), :dispatch | :review, map()) :: map()
  def verdict(ticket, phase, review) do
    moment = if phase == :dispatch, do: "Before dispatch", else: "At review"
    decision = recommendation(review)
    message = "#{moment} for ##{ticket}: #{decision}. #{evidence(review.evidence)}"

    %{kind: "work_overlap", finding_key: "work-#{phase}", priority: if(review.action == :build, do: 3, else: 2), ticket: ticket, action: decision, message: String.trim(message)}
  end

  @spec feature(map()) :: map()
  def feature(%{left: left, right: right, features: features, scope: scope, evidence: details}) do
    location = if scope == :within, do: "Within feature", else: "Across features"
    message = "#{location} #{Enum.join(features, ", ")}: #{reference(left)} overlaps #{reference(right)}. #{evidence(details)}"
    %{kind: "feature_overlap", priority: 2, action: "Review overlap", message: String.trim(message)}
  end

  @spec command(pos_integer(), String.t(), :open | :answered) :: map()
  def command(ticket, path, status) do
    label = if status == :answered, do: "earlier answer", else: "open Command"

    %{
      kind: "creator_question_overlap",
      finding_key: "command-#{path}",
      priority: 3,
      ticket: ticket,
      action: "View #{label}",
      message: "Creator question on ##{ticket} linked to the #{label} at #{path}."
    }
  end

  @spec wake(map()) :: :ok
  def wake(finding), do: Wake.publish(finding)

  @spec comment(map()) :: String.t()
  def comment(finding), do: "**Overlap review**\n\n" <> finding.message

  defp recommendation(%{action: :build}), do: "Build"
  defp recommendation(%{action: :unavailable}), do: "Overlap review unavailable"
  defp recommendation(%{action: :extend, target: target}), do: "Extend existing #{reference(target)}"
  defp recommendation(%{action: :fold, target: target}), do: "Fold into #{reference(target)}"

  defp reference(%{kind: :issue, number: number}), do: "ticket ##{number}"
  defp reference(%{kind: :open_pr, number: number}), do: "open PR ##{number}"
  defp reference(%{kind: :merged_pr, number: number}), do: "merged PR ##{number}"

  defp evidence(details) do
    parts =
      for {key, label} <- [title_terms: "Title terms", files: "Files", symbols: "Symbols"],
          terms = details |> Map.get(key, []) |> Enum.take(5),
          terms != [],
          do: "#{label}: #{Enum.map_join(terms, ", ", &"`#{&1}`")}."

    Enum.join(parts, " ")
  end
end
