defmodule Aiur.Orchestrator.EventTopics do
  @moduledoc """
  Parses and classifies orchestrator event bus topics.
  """

  @spec parse_pr_review_comment_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_pr_review_comment_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.pr\.review_comment\z}, topic) do
      [_, number] -> {:ok, number}
      _ -> :nomatch
    end
  end

  @spec parse_issue_commented_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_issue_commented_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.issue\.commented\z}, topic) do
      [_, number] -> {:ok, number}
      _ -> :nomatch
    end
  end

  @spec parse_pr_merged_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_pr_merged_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.pr\.merged\z}, topic) do
      [_, number] -> {:ok, number}
      _ -> :nomatch
    end
  end

  @spec parse_ci_failed_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_ci_failed_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.ci\.failed\z}, topic) do
      [_, number] -> {:ok, number}
      _ -> :nomatch
    end
  end

  @spec parse_pause_request_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_pause_request_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.agent\.pause\.request\z}, topic) do
      [_, identifier] -> {:ok, identifier}
      _ -> :nomatch
    end
  end

  @spec parse_branch_push_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_branch_push_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.branch\.push\z}, topic) do
      [_, identifier] -> {:ok, identifier}
      _ -> :nomatch
    end
  end

  @spec parse_system_branch_push_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_system_branch_push_topic(topic) do
    case Regex.run(~r{\Asystem\.([^.]+)\.branch\.push\z}, topic) do
      [_, branch] -> {:ok, branch}
      _ -> :nomatch
    end
  end

  # Single-pass topic classifier: runs each parser at most once and
  # returns a tagged tuple the caller pattern-matches on. Cheaper than
  # a `cond` that calls every parser twice (once for the match? test,
  # once to extract the identifier).
  @spec classify_event_topic(String.t()) :: {atom(), String.t()} | :nomatch
  def classify_event_topic(topic) do
    with :nomatch <- tag_topic(:pr_review_comment, parse_pr_review_comment_topic(topic)),
         :nomatch <- tag_topic(:issue_commented, parse_issue_commented_topic(topic)),
         :nomatch <- tag_topic(:pr_merged, parse_pr_merged_topic(topic)),
         :nomatch <- tag_topic(:ci_failed, parse_ci_failed_topic(topic)),
         :nomatch <- tag_topic(:pause_request, parse_pause_request_topic(topic)),
         :nomatch <- tag_topic(:branch_push, parse_branch_push_topic(topic)) do
      tag_topic(:system_branch_push, parse_system_branch_push_topic(topic))
    end
  end

  @spec tag_topic(atom(), {:ok, String.t()} | :nomatch) :: {atom(), String.t()} | :nomatch
  def tag_topic(tag, {:ok, identifier}), do: {tag, identifier}
  def tag_topic(_tag, :nomatch), do: :nomatch
end
