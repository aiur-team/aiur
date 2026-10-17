defmodule Aiur.Events.GithubWebhook.DepositLiveOrchestratorTest do
  @moduledoc """
  A deposit comment delivery must not reach the suite's live orchestrator (#4845).

  Without a tracker its comment-rework gate cannot resolve the issue state, so it
  would publish `comment_wake_state_unresolved` attention alerts on the shared bus
  and retry for about 30 seconds.
  """

  use Aiur.TestSupport.DepositCase

  alias Aiur.Events.{Exchange, GithubWebhook}

  @repo "owner/repo"

  test "a comment delivery raises no comment-wake attention from the live orchestrator" do
    topic = "ticket.#{ticket_number()}.agent.attention.comment_wake_state_unresolved"
    :ok = Exchange.subscribe("ticket.*.agent.attention.*")

    GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9311), repo: @repo)

    refute_receive {:event, %{topic: ^topic}}, 3_000
  end
end
