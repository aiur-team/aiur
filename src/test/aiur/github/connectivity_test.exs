defmodule Aiur.GitHub.ConnectivityTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

  describe "classify_ls_remote/1" do
    test "classifies bounded git timeouts explicitly" do
      assert Connectivity.classify_ls_remote({:git_ls_remote_timeout, 200, ""}) == :timeout
    end
  end

  describe "backoff_ms/3" do
    test "rate_limited reset waits are capped at one hour independently of the transport cap" do
      now = ~U[2026-08-09 21:00:00Z]

      assert Connectivity.backoff_ms(:rate_limited, 1, %{
               reset_at: "2026-08-09T22:00:00Z",
               now: now,
               retry_after: 30
             }) == 3_600_000

      assert Connectivity.backoff_ms(:rate_limited, 1, %{
               reset_at: "2026-08-09T23:00:00Z",
               now: now
             }) == 3_600_000

      assert 3_600_000 > Connectivity.max_backoff_ms()
    end

    test "rate_limited bounds malformed reset_at (wrong unit, far future, negative)" do
      now = ~U[2026-08-09 21:00:00Z]

      # Wrong unit: a numeric value is not an ISO-8601 string, so the reset wait
      # is ignored and the ordinary capped exponential fallback applies instead
      # of parking polling on the malformed value.
      assert Connectivity.backoff_ms(:rate_limited, 1, %{reset_at: 3_600_000, now: now}) ==
               Connectivity.backoff_ms(:dns, 1, %{})

      # Far future: a seconds-intended reset read as milliseconds (~41 days out)
      # is clamped to the one-hour reset cap, not honored for weeks.
      assert Connectivity.backoff_ms(:rate_limited, 1, %{
               reset_at: "2026-09-19T21:00:00Z",
               now: now
             }) == 3_600_000

      # Negative: the reset already passed, so the capped exponential fallback
      # applies rather than a pathological wait.
      assert Connectivity.backoff_ms(:rate_limited, 1, %{
               reset_at: "2026-08-09T20:00:00Z",
               now: now
             }) == Connectivity.backoff_ms(:dns, 1, %{})
    end

    test "rate_limited logs the raw reset value when the wait is clamped" do
      now = ~U[2026-08-09 21:00:00Z]
      raw_reset_at = "2026-09-19T21:00:00Z"

      log =
        capture_log(fn ->
          assert Connectivity.backoff_ms(:rate_limited, 1, %{
                   reset_at: raw_reset_at,
                   now: now
                 }) == 3_600_000
        end)

      assert log =~ "github_reset_backoff_clamped"
      assert log =~ "raw_reset_at=#{inspect(raw_reset_at)}"
    end

    test "rate_limited honors retry_after when present" do
      assert Connectivity.backoff_ms(:rate_limited, 1, %{retry_after: 30}) == 30_000
    end

    test "rate_limited clamps large retry_after values" do
      assert Connectivity.backoff_ms(:rate_limited, 1, %{retry_after: 3_600}) ==
               Connectivity.max_backoff_ms()
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

  describe "record_failure/5" do
    test "returns updated streaks and exponential backoff without emitting below threshold" do
      emit_fun = fn name, message, opts ->
        send(self(), {:alert, name, message, opts})
      end

      assert Connectivity.record_failure(%{}, :ls_remote, :dns, 30_000, emit_fun: emit_fun) ==
               {%{ls_remote: {:dns, 1}}, 1_000}

      refute_receive {:alert, _, _, _}, 100
    end

    test "emits system.github.connectivity_lost exactly once when a dns streak crosses the threshold" do
      emit_fun = fn name, message, opts ->
        send(self(), {:alert, name, message, opts})
      end

      {streaks, _delay} =
        Connectivity.record_failure(%{}, :ls_remote, :dns, 30_000,
          emit_fun: emit_fun,
          repo: "o/r"
        )

      {streaks, _delay} =
        Connectivity.record_failure(streaks, :ls_remote, :dns, 30_000,
          emit_fun: emit_fun,
          repo: "o/r"
        )

      refute_received {:alert, _, _, _}

      {streaks, _delay} =
        Connectivity.record_failure(streaks, :ls_remote, :dns, 30_000,
          emit_fun: emit_fun,
          repo: "o/r"
        )

      assert_receive {:alert, "system.github.connectivity_lost", message, opts}, 2000
      assert message =~ "DNS resolution failures"
      assert message =~ " for o/r"
      assert opts[:needs_attention] == true
      assert opts[:severity] == "warning"
      assert opts[:reason] == message

      Connectivity.record_failure(streaks, :ls_remote, :dns, 30_000,
        emit_fun: emit_fun,
        repo: "o/r"
      )

      refute_received {:alert, _, _, _}
    end

    test ":auth normalizes :escalate to max_backoff_ms" do
      emit_fun = fn _name, _message, _opts -> :ok end

      {_streaks, delay_ms} =
        Connectivity.record_failure(%{}, :ls_remote, :auth, 30_000, emit_fun: emit_fun)

      assert delay_ms == Connectivity.max_backoff_ms()
    end
  end

  describe "streak_count/2" do
    test "streak_count/2 returns the recorded count" do
      assert Connectivity.streak_count(%{ls_remote: {:dns, 4}}, :ls_remote) == 4
    end

    test "streak_count/2 defaults to 1 for unknown sources" do
      assert Connectivity.streak_count(%{}, :ls_remote) == 1
    end
  end
end
