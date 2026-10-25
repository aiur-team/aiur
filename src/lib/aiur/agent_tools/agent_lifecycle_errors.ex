defmodule Aiur.AgentTools.AgentLifecycleErrors do
  @moduledoc false

  alias Aiur.AgentTools.{Response, TicketState}

  @spec payload(term()) :: map()
  def payload(:no_issue_identifier),
    do: %{
      "error" => %{
        "message" => "Decision requests require a ticket identifier.",
        "reason" => "no_issue_identifier"
      }
    }

  def payload(:blocker_declarer_unavailable),
    do: %{
      "error" => %{
        "message" => "`aiur_declare_blocker` is unavailable in the current runtime context."
      }
    }

  def payload(:unblocker_unavailable),
    do: %{
      "error" => %{"message" => "`aiur_unblock` is unavailable in the current runtime context."}
    }

  def payload({:stale_review_base, detail}),
    do: %{
      "error" => %{
        "message" =>
          "Human-review refused: GitHub reports PR ##{detail.pr_number} conflicts with current origin/#{detail.base_branch}. " <>
            "Integrate the configured base, resolve the conflict, validate and push. " <>
            "Keep the PR ready before returning to ci-wait; wait for CI on the new head before requesting human-review. " <>
            "Never dequeue a pull request from the merge queue, or ask the Executor to, in order to update its branch.",
        "reason" => "stale_review_base",
        "detail" => Response.jsonable(detail)
      }
    }

  def payload(:ticket_state_setter_unavailable),
    do: %{
      "error" => %{
        "message" => "`aiur_set_ticket_state` is unavailable in the current runtime context."
      }
    }

  def payload({:draft_pr_cannot_enter_state, state, number}),
    do: %{
      "error" => %{
        "reason" => "draft_pr_cannot_enter_state",
        "state" => state,
        "pull_request" => number,
        "message" => "Mark the draft pull request ready before moving this ticket to #{state}."
      }
    }

  def payload(:missing_ticket_state),
    do: %{"error" => %{"message" => "`state` is required."}}

  def payload(:invalid_ticket_state),
    do: %{"error" => %{"message" => "`state` must be a string."}}

  def payload({:unsettable_ticket_state, state}),
    do: %{
      "error" => %{
        "message" =>
          "`state` must be one of: " <>
            Enum.join(TicketState.agent_settable_states(), ", ") <>
            ". `todo` is owned by dispatch, and `merging`/`cancelled` are Executor dispositions an agent must not claim.",
        "state" => state
      }
    }
end
