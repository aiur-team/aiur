defmodule Aiur.GitHub.ConnectivityTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.Connectivity

  # WHY: #617 — flaky GitHub DNS/auth failures used to only Logger.warning
  # forever, so an operator never learned the agents were wedged. The
  # escalation logic must raise a loud, operator-visible signal once a source
  # has failed repeatedly with the *same* fixable class (DNS or auth), and must
  # NOT escalate on a single blip or on transient/rate-limit classes that
  # self-heal.

  describe "note_failure/3 escalation" do
    test "does not escalate before the threshold of consecutive failures" do
      {streaks, alerts} = Connectivity.note_failure(%{}, :firehose, :dns)
      assert alerts == []
      assert {_streaks, []} = Connectivity.note_failure(streaks, :firehose, :dns)
    end

    test "escalates exactly once when consecutive :dns failures cross the threshold" do
      {streaks, alerts} =
        Enum.reduce(1..Connectivity.escalation_threshold(), {%{}, []}, fn _i, {acc, _} ->
          Connectivity.note_failure(acc, :firehose, :dns)
        end)

      assert [%{source: :firehose, classification: :dns, count: count}] = alerts
      assert count == Connectivity.escalation_threshold()

      # Still failing past the threshold must not re-spam the operator.
      assert {_streaks, []} = Connectivity.note_failure(streaks, :firehose, :dns)
    end

    test "escalates on repeated :auth failures (token expiry must be loud)" do
      {_streaks, alerts} =
        Enum.reduce(1..Connectivity.escalation_threshold(), {%{}, []}, fn _i, {acc, _} ->
          Connectivity.note_failure(acc, :comments, :auth)
        end)

      assert [%{source: :comments, classification: :auth}] = alerts
    end

    test "does not escalate on transient classes (:timeout, :rate_limited, :http)" do
      for class <- [:timeout, :rate_limited, :http, :tls, :transport] do
        {_streaks, alerts} =
          Enum.reduce(1..(Connectivity.escalation_threshold() + 2), {%{}, []}, fn _i, {acc, _} ->
            Connectivity.note_failure(acc, :firehose, class)
          end)

        assert alerts == [], "#{class} should not escalate to an operator blocker"
      end
    end

    test "switching failure class resets the streak (mixed failures don't escalate)" do
      streaks =
        Enum.reduce(1..(Connectivity.escalation_threshold() - 1), %{}, fn _i, acc ->
          {acc, _} = Connectivity.note_failure(acc, :firehose, :dns)
          acc
        end)

      # One auth failure mid-streak resets the dns counter, so the next dns
      # failure is streak=1 again — no escalation.
      {streaks, _} = Connectivity.note_failure(streaks, :firehose, :auth)
      {_streaks, alerts} = Connectivity.note_failure(streaks, :firehose, :dns)
      assert alerts == []
    end

    test "tracks sources independently" do
      streaks =
        Enum.reduce(1..(Connectivity.escalation_threshold() - 1), %{}, fn _i, acc ->
          {acc, _} = Connectivity.note_failure(acc, :firehose, :dns)
          acc
        end)

      # A failure on a *different* source must not push :firehose over the edge.
      {_streaks, alerts} = Connectivity.note_failure(streaks, :ls_remote, :dns)
      assert alerts == []
    end
  end

  describe "note_success/2" do
    test "clears the streak so recovery re-arms a future escalation" do
      streaks =
        Enum.reduce(1..(Connectivity.escalation_threshold() - 1), %{}, fn _i, acc ->
          {acc, _} = Connectivity.note_failure(acc, :firehose, :dns)
          acc
        end)

      streaks = Connectivity.note_success(streaks, :firehose)

      # After recovery, it takes a full fresh threshold to escalate again.
      {_streaks, alerts} = Connectivity.note_failure(streaks, :firehose, :dns)
      assert alerts == []
    end
  end

  describe "backoff_ms/3" do
    test "rate_limited honors retry_after when present" do
      assert Connectivity.backoff_ms(:rate_limited, 1, %{retry_after: 30}) == 30_000
    end

    test "rate_limited honors poll_interval when retry_after absent" do
      assert Connectivity.backoff_ms(:rate_limited, 1, %{poll_interval: 12}) == 12_000
    end

    test "dns/timeout grow exponentially with attempt and stay capped" do
      a1 = Connectivity.backoff_ms(:dns, 1, %{})
      a2 = Connectivity.backoff_ms(:dns, 2, %{})
      a_big = Connectivity.backoff_ms(:dns, 50, %{})

      assert a2 > a1
      assert a_big <= Connectivity.max_backoff_ms()
    end

    test "auth escalates immediately rather than backing off and retrying" do
      assert Connectivity.backoff_ms(:auth, 5, %{}) == :escalate
    end
  end
end
