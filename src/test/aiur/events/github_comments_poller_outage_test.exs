defmodule Aiur.Events.GithubCommentsPollerOutageTest do
  use Aiur.TestSupport
  use Aiur.TestSupport.EventTicket
  import Aiur.TestSupport.CommentsPollerFixture

  alias Aiur.Events.Exchange
  alias Aiur.Events.GithubCommentsPoller

  setup :comments_poller_env

  describe "PR review submission polling" do
    test "reports an error and zero count when PR reviews fetch fails" do
      ticket = ticket_id()
      fixture_value0 = "/issues/#{ticket}/comments?"
      fixture_value1 = "aiur/#{ticket}"
      codeowners = ensure_codeowners!("* @its-everdred\n")

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, fixture_value0) ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls?") ->
            {:ok,
             %{
               status: 200,
               body: [%{"number" => 77, "head" => %{"ref" => fixture_value1, "repo" => %{"full_name" => "owner/repo"}}}]
             }}

          String.contains?(url, "/issues/77/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/graphql") ->
            empty_review_threads_response()

          String.contains?(url, "/pulls/77/reviews") ->
            {:error, :timeout}
        end
      end

      assert {:ok, %{count: 0, errors: [{^ticket, {:pr_reviews, _}}]}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun
               )

      stop_codeowners(codeowners)
    end

    test "a transient PR reviews failure does not stall the issue-comment watermark" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.issue.commented"
      fixture_value1 = "/issues/#{ticket}/comments?"
      fixture_value2 = "aiur/#{ticket}"
      # Regression for #1389 P0: if /reviews 403s, the issue-comment since must
      # still advance. Previously errors == [] gated advance_since unconditionally.
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, fixture_value1) ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "id" => 99_001,
                   "body" => "looks good to me",
                   "updated_at" => "2026-06-24T12:00:00Z",
                   "user" => %{"login" => "its-everdred"}
                 }
               ]
             }}

          String.contains?(url, "/pulls?") ->
            {:ok,
             %{
               status: 200,
               body: [%{"number" => 77, "head" => %{"ref" => fixture_value2, "repo" => %{"full_name" => "owner/repo"}}}]
             }}

          String.contains?(url, "/issues/77/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/graphql") ->
            empty_review_threads_response()

          String.contains?(url, "/pulls/77/reviews") ->
            {:error, :timeout}
        end
      end

      assert {:ok, %{since: %{^ticket => since}, errors: [{^ticket, {:pr_reviews, _}}]}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun
               )

      assert since > "2026-06-24T11:00:00Z", "since must advance past the new comment even when /reviews fails"
      assert_receive {:event, %{topic: ^fixture_topic0}}, 500
      stop_codeowners(codeowners)
    end

    test "a review remains discoverable after issue comments advance while review reads are disabled" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      fixture_value1 = "/issues/#{ticket}/comments?"
      fixture_value2 = "aiur/#{ticket}"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")
      review = pr_review(9_081, "its-everdred", "CHANGES_REQUESTED", "please rework", "2026-06-24T12:00:00Z")

      first_request = fn %{url: url} ->
        cond do
          String.contains?(url, fixture_value1) ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "id" => 99_081,
                   "body" => "CI update",
                   "updated_at" => "2026-06-24T12:30:00Z",
                   "user" => %{"login" => "its-everdred"}
                 }
               ]
             }}

          String.contains?(url, "/pulls?") ->
            {:ok,
             %{
               status: 200,
               body: [%{"number" => 77, "head" => %{"ref" => fixture_value2, "repo" => %{"full_name" => "owner/repo"}}}]
             }}

          String.contains?(url, "/issues/77/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/graphql") ->
            empty_review_threads_response()

          String.contains?(url, "/pulls/77/reviews") ->
            flunk("review endpoint must stay disabled during ci-wait")
        end
      end

      assert {:ok, %{since: %{^ticket => issue_since}, pr_review_seen_at: review_seen_at}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 review_submission_targets: MapSet.new(),
                 request_fun: first_request
               )

      assert issue_since > "2026-06-24T12:00:00Z"

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 since: %{ticket => issue_since},
                 pr_review_seen_at: review_seen_at,
                 repo: "owner/repo",
                 review_submission_targets: MapSet.new([ticket]),
                 request_fun: request_fun_with_reviews([review])
               )

      assert_receive {:event, %{topic: ^fixture_topic0, comment: %{"id" => 9_081}}}, 500
      stop_codeowners(codeowners)
    end
  end

  # #1680 criterion 6: #1427's review poller has to keep working as the fallback
  # path for review submissions. `poll_pr_review_submissions/5` picks its cutoff
  # as `pr_review_seen_at || current_target_since || boot cutoff`, so a review is
  # recovered exactly when a cursor predating it reaches this opt.
  #
  # These pin both halves of that rule, including the half the operator
  # explicitly accepted on 2026-08-10: cursors do not survive a restart, so a
  # review submitted while the daemon was down is dropped rather than recovered.
  # That is the accepted cost of dropping gap detection, and the second test
  # exists so the behavior is pinned rather than assumed.
  #
  # The daemon is down 17:00 -> 18:00 and the review lands at 17:30. The two
  # tests differ only in whether a cursor was supplied, so the recovery
  # assertion cannot pass for an unrelated reason.
  describe "PR review submissions across a daemon outage" do
    @outage_boot_time DateTime.to_unix(~U[2026-07-12 18:00:00Z])
    @review_during_outage "2026-07-12T17:30:00Z"
    @cursor_before_outage "2026-07-12T17:00:00Z"

    test "recovers a review submitted while the daemon was down from a cursor predating it" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_101, "its-everdred", "CHANGES_REQUESTED", "reviewed during the outage", @review_during_outage)

      assert {:ok, %{count: 1, errors: [], pr_review_seen_at: seen_at}} =
               GithubCommentsPoller.poll([ticket],
                 repo: "owner/repo",
                 boot_time: @outage_boot_time,
                 pr_review_seen_at: %{ticket => @cursor_before_outage},
                 request_fun: request_fun_with_reviews([review])
               )

      assert_receive {:event,
                      %{
                        topic: ^fixture_topic0,
                        author_trusted?: true,
                        comment: %{"id" => 9_101, "state" => "CHANGES_REQUESTED"}
                      }},
                     500

      # The cursor advances past the recovered review, so the next sweep does
      # not republish it.
      assert seen_at == %{ticket => @review_during_outage}

      stop_codeowners(codeowners)
    end

    test "drops the same review when no cursor survived the restart" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_102, "its-everdred", "CHANGES_REQUESTED", "reviewed during the outage", @review_during_outage)

      assert {:ok, %{count: 0, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 repo: "owner/repo",
                 boot_time: @outage_boot_time,
                 request_fun: request_fun_with_reviews([review])
               )

      refute_receive {:event, %{topic: ^fixture_topic0}}, 200

      stop_codeowners(codeowners)
    end
  end
end
