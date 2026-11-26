defmodule Aiur.AgentTools.ReviewThreadsTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentTools.ReviewThreads

  test "uses review thread callbacks installed by the application composition root" do
    old_replier = Application.get_env(:aiur, :review_thread_replier)
    old_resolver = Application.get_env(:aiur, :review_thread_resolver)

    on_exit(fn ->
      if is_nil(old_replier),
        do: Application.delete_env(:aiur, :review_thread_replier),
        else: Application.put_env(:aiur, :review_thread_replier, old_replier)

      if is_nil(old_resolver),
        do: Application.delete_env(:aiur, :review_thread_resolver),
        else: Application.put_env(:aiur, :review_thread_resolver, old_resolver)
    end)

    Application.put_env(:aiur, :review_thread_replier, fn id, body, _opts ->
      {:ok, %{"latest_comment" => %{"id" => id, "body" => body}}}
    end)

    Application.put_env(:aiur, :review_thread_resolver, fn id, opts ->
      {:ok, %{"resolved" => id, "terminal_reply_body" => opts[:terminal_reply_body]}}
    end)

    reply =
      ReviewThreads.execute("aiur_reply_review_thread", %{"review_thread_id" => "PRRT_x", "body" => "Fixed."}, [])

    resolve =
      ReviewThreads.execute(
        "aiur_resolve_review_thread",
        %{"review_thread_id" => "PRRT_x", "terminal_reply_body" => "Done."},
        []
      )

    assert Jason.decode!(reply["output"]) == %{"latest_comment" => %{"id" => "PRRT_x", "body" => "Fixed."}}
    assert Jason.decode!(resolve["output"]) == %{"resolved" => "PRRT_x", "terminal_reply_body" => "Done."}
  end

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
