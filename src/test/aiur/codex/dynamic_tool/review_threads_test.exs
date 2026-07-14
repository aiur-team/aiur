defmodule Aiur.Codex.DynamicTool.ReviewThreadsTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.DynamicTool.ReviewThreads

  describe "input validation — aiur_reply_review_thread" do
    test "missing review_thread_id returns required error" do
      response =
        ReviewThreads.execute(
          "aiur_reply_review_thread",
          %{"body" => "Fixed."},
          review_thread_replier: fn _id, _body, _opts -> {:ok, %{}} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "review_thread_id"
    end

    test "missing body returns required error" do
      response =
        ReviewThreads.execute(
          "aiur_reply_review_thread",
          %{"review_thread_id" => "PRRT_abc"},
          review_thread_replier: fn _id, _body, _opts -> {:ok, %{}} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "body"
    end

    test "non-map arguments return invalid arguments error" do
      response =
        ReviewThreads.execute(
          "aiur_reply_review_thread",
          "not a map",
          review_thread_replier: fn _id, _body, _opts -> {:ok, %{}} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "aiur_reply_review_thread"
    end
  end

  describe "input validation — aiur_resolve_review_thread" do
    test "missing review_thread_id returns required error" do
      response =
        ReviewThreads.execute(
          "aiur_resolve_review_thread",
          %{"terminal_reply_body" => "Done."},
          review_thread_resolver: fn _id, _opts -> {:ok, %{}} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "review_thread_id"
    end

    test "missing terminal_reply_body returns required error" do
      response =
        ReviewThreads.execute(
          "aiur_resolve_review_thread",
          %{"review_thread_id" => "PRRT_abc"},
          review_thread_resolver: fn _id, _opts -> {:ok, %{}} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "terminal_reply_body"
    end

    test "non-map arguments return invalid arguments error" do
      response =
        ReviewThreads.execute(
          "aiur_resolve_review_thread",
          nil,
          review_thread_resolver: fn _id, _opts -> {:ok, %{}} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "aiur_resolve_review_thread"
    end
  end

  describe "execute/3 — aiur_reply_review_thread" do
    test "happy path via injected replier" do
      test_pid = self()

      response =
        ReviewThreads.execute(
          "aiur_reply_review_thread",
          %{"review_thread_id" => "PRRT_abc", "body" => "Fixed."},
          review_thread_replier: fn id, body, opts ->
            send(test_pid, {:reply, id, body, opts})
            {:ok, %{"verified" => true}}
          end
        )

      assert response["success"] == true
      assert_received {:reply, "PRRT_abc", "Fixed.", []}
      assert Jason.decode!(response["output"]) == %{"verified" => true}
    end

    test "records the mutation identity rather than a later verification comment" do
      test_pid = self()

      response =
        ReviewThreads.execute(
          "aiur_reply_review_thread",
          %{"review_thread_id" => "PRRT_origin", "body" => "Fixed."},
          review_thread_replier: fn _id, _body, _opts ->
            {:ok,
             %{
               verified: true,
               published_comment: %{"id" => 701},
               verification: %{"latest_comment" => %{"id" => 702}}
             }}
          end,
          agent_comment_origin_recorder: fn comment ->
            send(test_pid, {:recorded_origin, comment})
            :ok
          end
        )

      assert response["success"] == true
      assert_received {:recorded_origin, %{"id" => 701}}
    end

    test "persists reply intent before publishing and finalizes the exact mutation identity" do
      test_pid = self()

      response =
        ReviewThreads.execute(
          "aiur_reply_review_thread",
          %{"review_thread_id" => "PRRT_pending", "body" => "Fixed."},
          agent_comment_origin_operation_id: "reply-pending-704",
          agent_comment_origin_begin: fn operation_id ->
            send(test_pid, {:origin_begin, operation_id})
            :ok
          end,
          agent_comment_origin_complete: fn operation_id, comment ->
            send(test_pid, {:origin_complete, operation_id, comment})
            :ok
          end,
          review_thread_replier: fn _id, _body, _opts ->
            assert_received {:origin_begin, "reply-pending-704"}
            {:ok, %{verified: true, published_comment: %{"id" => 704}}}
          end
        )

      assert response["success"] == true
      assert_received {:origin_complete, "reply-pending-704", %{"id" => 704}}
    end

    test "keeps reply publication and origin recording in one transaction" do
      test_pid = self()

      response =
        ReviewThreads.execute(
          "aiur_reply_review_thread",
          %{"review_thread_id" => "PRRT_transaction", "body" => "Fixed."},
          agent_comment_origin_transaction: fn operation ->
            send(test_pid, :origin_transaction_started)
            result = operation.()
            send(test_pid, :origin_transaction_finished)
            result
          end,
          review_thread_replier: fn _id, _body, _opts ->
            send(test_pid, :reply_published)

            {:ok,
             %{
               verified: true,
               published_comment: %{"id" => 702},
               verification: %{"latest_comment" => %{"id" => 702}}
             }}
          end,
          agent_comment_origin_recorder: fn comment ->
            send(test_pid, {:origin_recorded, comment})
            :ok
          end
        )

      assert response["success"] == true
      assert_received :origin_transaction_started
      assert_received :reply_published
      assert_received {:origin_recorded, %{"id" => 702}}
      assert_received :origin_transaction_finished
    end

    test "returns a failure when a verified reply cannot be recorded" do
      response =
        ReviewThreads.execute(
          "aiur_reply_review_thread",
          %{"review_thread_id" => "PRRT_origin", "body" => "Fixed."},
          review_thread_replier: fn _id, _body, _opts ->
            {:ok,
             %{
               verified: true,
               published_comment: %{"id" => 701},
               verification: %{"latest_comment" => %{"id" => 701}}
             }}
          end,
          agent_comment_origin_recorder: fn _comment -> {:error, :disk_full} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] == "agent_comment_origin_not_recorded"
    end

    test "records a published reply when verification fails after the GitHub mutation" do
      test_pid = self()
      verification_failure = %{published_comment: %{"id" => 703}, reason: :verification_timeout}

      response =
        ReviewThreads.execute(
          "aiur_reply_review_thread",
          %{"review_thread_id" => "PRRT_origin", "body" => "Fixed."},
          review_thread_replier: fn _id, _body, _opts ->
            {:error, {:review_thread_reply_not_verified, verification_failure}}
          end,
          agent_comment_origin_recorder: fn comment ->
            send(test_pid, {:recorded_origin_after_verify_failure, comment})
            :ok
          end
        )

      assert response["success"] == false
      assert_received {:recorded_origin_after_verify_failure, %{"id" => 703}}
    end

    test "surfaces persistence failure after a published but unverified reply" do
      verification_failure = %{published_comment: %{"id" => 704}, reason: :verification_timeout}

      response =
        ReviewThreads.execute(
          "aiur_reply_review_thread",
          %{"review_thread_id" => "PRRT_origin", "body" => "Fixed."},
          review_thread_replier: fn _id, _body, _opts ->
            {:error, {:review_thread_reply_not_verified, verification_failure}}
          end,
          agent_comment_origin_recorder: fn _comment -> {:error, :disk_full} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] == "agent_comment_origin_not_recorded"
    end

    test "review_thread_reply_not_verified renders failure" do
      response =
        ReviewThreads.execute(
          "aiur_reply_review_thread",
          %{"review_thread_id" => "PRRT_x", "body" => "Reply."},
          review_thread_replier: fn _id, _body, _opts ->
            {:error, {:review_thread_reply_not_verified, %{attempts: 1}}}
          end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] == "review_thread_reply_not_verified"
    end
  end

  describe "execute/3 — aiur_resolve_review_thread" do
    test "happy path via injected resolver" do
      test_pid = self()

      response =
        ReviewThreads.execute(
          "aiur_resolve_review_thread",
          %{"review_thread_id" => "PRRT_done", "terminal_reply_body" => "Done."},
          review_thread_resolver: fn id, opts ->
            send(test_pid, {:resolve, id, opts})
            {:ok, %{"resolved" => true}}
          end
        )

      assert response["success"] == true
      assert_received {:resolve, "PRRT_done", [terminal_reply_body: "Done."]}
    end

    test "review_thread_resolution_not_permitted renders explicit failure" do
      response =
        ReviewThreads.execute(
          "aiur_resolve_review_thread",
          %{"review_thread_id" => "PRRT_denied", "terminal_reply_body" => "Done."},
          review_thread_resolver: fn _id, _opts ->
            {:error, {:review_thread_resolution_not_permitted, %{reason: "no scope"}}}
          end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] == "review_thread_resolution_not_permitted"
    end
  end
end
