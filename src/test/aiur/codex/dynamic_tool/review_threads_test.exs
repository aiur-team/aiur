defmodule Aiur.Codex.DynamicTool.ReviewThreadsTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.DynamicTool.ReviewThreads

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
