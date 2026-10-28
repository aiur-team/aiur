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

  # DESIGN-E4 decision 2, epic #6620 resolution (2026-10-25): only listed kinds are on.
  # Semantic icon keys are implementation metadata; the resolution names no icon library.
  @catalogue [
    {:progress, "Progress", :chart_bar, true, :exact},
    {:phase, "Phase", :flag, false, :exact},
    {:push, "Pushed", :arrow_up_tray, true, :causal},
    {:pr_opened, "PR opened", :code_bracket, true, :causal},
    {:pr_merged, "PR merged", :code_bracket_square, true, :causal},
    {:ci, "CI result", :check_circle, false, :observed},
    {:review_comment, "Review comment", :chat_bubble_left, false, :observed},
    {:command_requested, "Command requested", :question_mark_circle, true, :exact},
    {:command_resolved, "Command answered", :check_circle, true, :exact},
    {:attention, "Attention", :exclamation_triangle, false, :exact},
    {:executor_progress, "Executor progress", :user, false, :causal}
  ]
  @entries Map.new(@catalogue, fn {kind, label, icon, visible, precision} ->
             {kind, %{kind: kind, label: label, icon: icon, default_visible: visible, best_precision: precision}}
           end)
  @kind_names Map.new(@entries, fn {kind, _} -> {Atom.to_string(kind), kind} end)
  @type kind :: :progress | :phase | :push | :pr_opened | :pr_merged | :ci | :review_comment | :command_requested | :command_resolved | :attention | :executor_progress
  @type entry :: %{kind: kind(), label: String.t(), icon: atom(), default_visible: boolean(), best_precision: :exact | :causal | :observed}

  @doc "Catalogue kinds in navigation order. Journals retain string kind names."
  @spec kinds() :: [kind()]
  def kinds, do: Enum.map(@catalogue, &elem(&1, 0))

  @spec entry(atom() | String.t()) :: entry() | nil
  def entry(kind) when is_binary(kind), do: entry(Map.get(@kind_names, kind))
  def entry(kind), do: Map.get(@entries, kind)

  @doc "Payload-aware label, bounded to 60 characters; never includes body, title or Command text."
  @spec label(atom() | String.t(), map()) :: String.t()
  def label(kind, payload) do
    case entry(kind) do
      nil -> "Event"
      %{kind: known_kind} -> known_kind |> payload_label(payload) |> String.slice(0, 60)
    end
  end

  defp payload_label(:progress, payload) do
    case field(payload, :percent) do
      percent when is_integer(percent) -> "Progress #{percent}%"
      _ -> "Progress"
    end
  end

  defp payload_label(:phase, payload) do
    case field(payload, :phase) do
      phase when is_binary(phase) and phase != "" -> "Phase: " <> phase
      _ -> "Phase"
    end
  end

  defp payload_label(:push, payload) do
    case field(payload, :sha) do
      sha when is_binary(sha) and sha != "" -> "Pushed " <> String.slice(sha, 0, 7)
      _ -> "Pushed"
    end
  end

  defp payload_label(kind, payload) when kind in [:pr_opened, :pr_merged] do
    action = if kind == :pr_opened, do: "opened", else: "merged"

    case field(field(payload, :pr), :number) do
      number when is_integer(number) and number > 0 -> "PR ##{number} #{action}"
      _ -> "PR " <> action
    end
  end

  defp payload_label(:ci, payload) do
    case suffix(field(payload, :topic)) do
      "ci.passed" -> "CI passed"
      "ci.failed" -> "CI failed"
      _ -> "CI result"
    end
  end

  defp payload_label(:review_comment, payload) do
    if suffix(field(payload, :topic)) == "issue.commented", do: "Comment", else: "Review comment"
  end

  defp payload_label(:attention, payload), do: Aiur.AgentEventFeed.topic_label(field(payload, :topic))

  defp payload_label(:executor_progress, payload) do
    topic = String.replace_prefix(field(payload, :topic) || "executor.progress", "executor.", "")
    "Executor: " <> (topic |> String.replace(~r/[._-]+/u, " ") |> String.capitalize())
  end

  defp payload_label(kind, _payload), do: entry(kind).label
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_, _), do: nil
  defp suffix("ticket." <> rest), do: rest |> String.split(".", parts: 2) |> List.last()
  defp suffix(topic), do: topic

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
