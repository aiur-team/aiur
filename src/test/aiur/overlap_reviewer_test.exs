defmodule Aiur.OverlapReviewerTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionPubSub, Issue, OverlapReviewer}
  alias Aiur.OverlapReviewer.Corpus

  test "dispatch, review, feature scans and Command links publish distinct overlap reports" do
    tester = self()
    now = DateTime.utc_now()

    corpus =
      Corpus.build(
        "owner/repo",
        [
          %{identifier: "41", title: "Persist command delivery receipts", description: "Use src/lib/receipt.ex and Receipt.persist/1"},
          %{identifier: "42", title: "Replace dashboard header font", description: ""}
        ],
        [
          %{
            "number" => 72,
            "state" => "open",
            "title" => "Persist command delivery receipts",
            "body" => "Refs #43\nUse src/lib/receipt.ex and Receipt.persist/1"
          }
        ],
        [],
        now,
        DateTime.to_unix(now, :millisecond)
      )

    server =
      start_supervised!(
        {OverlapReviewer,
         interval_ms: 60_000,
         subscribe?: false,
         capture: fn -> {:ok, corpus} end,
         memberships: fn -> {:ok, %{41 => ["commands"], 43 => ["delivery"]}} end,
         wake: fn finding -> send(tester, {:wake, finding}) end,
         comment: fn ticket, body ->
           if ticket == 41 and is_nil(Process.get(:retry_probe)) do
             Process.put(:retry_probe, true)
             send(tester, :comment_failed)
             {:error, :fixture_outage}
           else
             send(tester, {:comment, ticket, body})
             :ok
           end
         end}
      )

    assert_receive {:wake, %{kind: "feature_overlap", message: feature}}, 1_000
    assert feature =~ "Across features commands, delivery"
    assert feature =~ "ticket #41 overlaps open PR #72"

    assert :ok = OverlapReviewer.before_dispatch(%Issue{identifier: "41", title: "Persist command delivery receipts", description: "Use src/lib/receipt.ex and Receipt.persist/1"})
    assert_receive {:wake, %{kind: "work_overlap", action: "Extend existing open PR #72", finding_key: "work-dispatch"}}, 1_000
    assert_receive :comment_failed, 1_000
    send(server, :tick)
    assert_receive {:comment, 41, dispatch_body}, 1_000
    assert dispatch_body =~ "Before dispatch for #41"
    assert dispatch_body =~ "Files: `src/lib/receipt.ex`"

    pr = %{"number" => 79, "title" => "Persist command delivery receipts", "body" => "Use src/lib/receipt.ex", "head" => %{"sha" => String.duplicate("a", 40)}}
    send(server, {:event, %{topic: "ticket.42.pr.ready_for_review", pr: pr}})
    assert_receive {:wake, %{kind: "work_overlap", action: "Extend existing open PR #72", finding_key: "work-review"}}, 1_000
    assert_receive {:comment, 42, review_body}, 1_000
    assert review_body =~ "At review for #42"

    assert :ok = DecisionPubSub.broadcast_creator_overlap("41", %{command_path: "/commands/ticket%3A40%3Aprior", status: :answered})
    assert_receive {:wake, %{kind: "creator_question_overlap", message: command}}, 1_000
    assert command =~ "/commands/ticket%3A40%3Aprior"
  end
end
