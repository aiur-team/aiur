defmodule Aiur.Conversation.JumpPoints do
  @moduledoc "Topic-to-kind catalogue for durable conversation jump points."

  @kinds %{
    "agent.progress" => "progress",
    "agent.progress.checkin" => "progress",
    "agent.progress.phase" => "phase",
    "branch.push" => "push",
    "pr.opened" => "pr_opened",
    "pr.merged" => "pr_merged",
    "ci.passed" => "ci",
    "ci.failed" => "ci",
    "pr.review_comment" => "review_comment",
    "issue.commented" => "review_comment",
    "agent.decision.requested" => "command_requested",
    "agent.decision.resolved" => "command_resolved",
    "agent.blocked" => "attention"
  }

  @spec kind_for(String.t()) :: String.t() | nil
  def kind_for("executor." <> _), do: "executor_progress"

  def kind_for("ticket." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [_, "agent.phase." <> _] -> "phase"
      [_, "agent.attention." <> _] -> "attention"
      [_, suffix] -> Map.get(@kinds, suffix)
      _ -> nil
    end
  end

  def kind_for(_), do: nil
end
