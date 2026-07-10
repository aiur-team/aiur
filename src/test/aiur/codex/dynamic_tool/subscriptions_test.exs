defmodule Aiur.Codex.DynamicTool.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.DynamicTool.Subscriptions

  describe "execute/3 — aiur_subscribe" do
    test "subscribe via injected closure succeeds" do
      test_pid = self()

      response =
        Subscriptions.execute(
          "aiur_subscribe",
          %{"topic_pattern" => "ticket.42.#"},
          subscriber: fn pattern ->
            send(test_pid, {:subscribed, pattern})
            :ok
          end
        )

      assert response["success"] == true
      assert_received {:subscribed, "ticket.42.#"}
    end

    test "missing subscriber returns unavailable error" do
      response =
        Subscriptions.execute(
          "aiur_subscribe",
          %{"topic_pattern" => "ticket.42.#"},
          []
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "unavailable"
    end
  end

  describe "execute/3 — aiur_unsubscribe" do
    test "unsubscribe via injected closure succeeds" do
      test_pid = self()

      response =
        Subscriptions.execute(
          "aiur_unsubscribe",
          %{"topic_pattern" => "ticket.42.#"},
          unsubscriber: fn pattern ->
            send(test_pid, {:unsubscribed, pattern})
            :ok
          end
        )

      assert response["success"] == true
      assert_received {:unsubscribed, "ticket.42.#"}
    end

    test "missing unsubscriber returns unavailable error" do
      response =
        Subscriptions.execute(
          "aiur_unsubscribe",
          %{"topic_pattern" => "ticket.42.#"},
          []
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "unavailable"
    end
  end

  describe "normalize_topic_pattern/1" do
    test "rejects double-dot pattern" do
      response =
        Subscriptions.execute(
          "aiur_subscribe",
          %{"topic_pattern" => "ticket..101"},
          subscriber: fn _ -> :ok end
        )

      assert response["success"] == false
    end

    test "rejects leading-dot pattern" do
      response =
        Subscriptions.execute(
          "aiur_subscribe",
          %{"topic_pattern" => ".bad"},
          subscriber: fn _ -> :ok end
        )

      assert response["success"] == false
    end

    test "rejects trailing-dot pattern" do
      response =
        Subscriptions.execute(
          "aiur_subscribe",
          %{"topic_pattern" => "bad."},
          subscriber: fn _ -> :ok end
        )

      assert response["success"] == false
    end

    test "rejects missing pattern" do
      response =
        Subscriptions.execute(
          "aiur_subscribe",
          %{},
          subscriber: fn _ -> :ok end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "required"
    end

    test "accepts valid patterns" do
      for pattern <- ["ticket.42.#", "*.*.branch.push", "custom.slug"] do
        response =
          Subscriptions.execute(
            "aiur_subscribe",
            %{"topic_pattern" => pattern},
            subscriber: fn _ -> :ok end
          )

        assert response["success"] == true, "expected #{pattern} to be accepted"
      end
    end
  end
end
