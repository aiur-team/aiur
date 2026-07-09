defmodule Aiur.Codex.EventNormalizerTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.EventNormalizer

  describe "normalize_event/1 — usage extraction" do
    test "extracts total_token_usage from deep params path" do
      usage = %{"input_tokens" => 100, "output_tokens" => 50, "total_tokens" => 150}

      event = %{
        "params" => %{
          "msg" => %{"payload" => %{"info" => %{"total_token_usage" => usage}}}
        }
      }

      result = EventNormalizer.normalize_event(event)
      assert result[:usage][:input_tokens] == 100
      assert result[:usage][:output_tokens] == 50
    end

    test "extracts tokenUsage.total from params" do
      usage = %{"input_tokens" => 5, "output_tokens" => 3, "total_tokens" => 8}
      event = %{"params" => %{"tokenUsage" => %{"total" => usage}}}

      result = EventNormalizer.normalize_event(event)
      assert result[:usage][:input_tokens] == 5
    end

    test "extracts usage from turn/completed method events" do
      usage = %{"input_tokens" => 20, "output_tokens" => 10, "total_tokens" => 30}

      event = %{
        "method" => "turn/completed",
        "usage" => usage
      }

      result = EventNormalizer.normalize_event(event)
      assert result[:usage][:input_tokens] == 20
    end

    test "extracts usage from turn/completed under params" do
      usage = %{"input_tokens" => 7, "output_tokens" => 4, "total_tokens" => 11}

      event = %{
        "method" => "turn/completed",
        "params" => %{"usage" => usage}
      }

      result = EventNormalizer.normalize_event(event)
      assert result[:usage][:input_tokens] == 7
    end

    test "sets nil usage when no token data present" do
      result = EventNormalizer.normalize_event(%{"method" => "notification"})
      assert result[:usage] == nil
    end

    test "extracts usage from event payload key" do
      usage = %{"input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 3}

      event = %{payload: %{"method" => "turn/completed", "usage" => usage}}
      result = EventNormalizer.normalize_event(event)
      assert result[:usage][:input_tokens] == 1
    end
  end

  describe "normalize_event/1 — rate_limits extraction" do
    test "extracts rate_limits map with limit_id and buckets" do
      rate_limits = %{"limit_id" => "rl-1", "primary" => %{"remaining" => 100}}
      event = %{"rate_limits" => rate_limits}

      result = EventNormalizer.normalize_event(event)
      assert result[:rate_limits] == rate_limits
    end

    test "extracts rate_limits from atom key" do
      rate_limits = %{"limit_name" => "tier-1", "secondary" => %{}}
      event = %{rate_limits: rate_limits}

      result = EventNormalizer.normalize_event(event)
      assert result[:rate_limits] == rate_limits
    end

    test "extracts nested rate_limits from payload" do
      rate_limits = %{"limit_id" => "rl-x", "credits" => %{}}
      event = %{"payload" => %{"rate_limits" => rate_limits}}

      result = EventNormalizer.normalize_event(event)
      assert result[:rate_limits] == rate_limits
    end

    test "sets nil rate_limits when none present" do
      result = EventNormalizer.normalize_event(%{"method" => "turn/started"})
      assert result[:rate_limits] == nil
    end
  end

  describe "normalize_event/1 — combined" do
    test "normalizes both usage and rate_limits in one call" do
      usage = %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
      rate_limits = %{"limit_id" => "rl-1", "primary" => %{}}

      event = %{
        "method" => "turn/completed",
        "usage" => usage,
        "rate_limits" => rate_limits
      }

      result = EventNormalizer.normalize_event(event)
      assert result[:usage][:input_tokens] == 10
      assert result[:rate_limits] == rate_limits
    end
  end
end
