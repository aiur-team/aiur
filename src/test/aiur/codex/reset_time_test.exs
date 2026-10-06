defmodule Aiur.Codex.ResetTimeTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.{ExhaustedReset, NotificationPolicy, ResetTime}
  alias Aiur.Config.Schema

  @zone "America/Los_Angeles"

  test "parses the exact Khala refusal date in the app-server host zone, rounded up to the end of its minute" do
    # "try again at Sep 21st, 2026 6:26 PM" was printed on a PDT host. The
    # rollout's structured resets_at (1790040385) is 2026-09-22T01:26:25Z, so
    # the start of the printed minute (01:26:00Z) would resume 25s early.
    assert ResetTime.parse("Sep 21st, 2026 6:26 PM", ~U[2026-09-18 09:20:37Z], @zone) ==
             "2026-09-22T01:27:00Z"

    assert ResetTime.parse("Sep 21st, 2026 6:26 PM", ~U[2026-09-18 09:20:37Z], "Etc/UTC") ==
             "2026-09-21T18:27:00Z"
  end

  test "a refusal read inside the printed minute resets today, not tomorrow" do
    # 6:26:30 PM PDT: the reset is still ahead, at the end of 6:26.
    assert ResetTime.parse("6:26 PM", ~U[2026-09-22 01:26:30Z], @zone) == "2026-09-22T01:27:00Z"
  end

  test "a clock time without a date is its next occurrence" do
    assert ResetTime.parse("11:43 PM", ~U[2026-09-18 09:20:37Z], @zone) == "2026-09-19T06:44:00Z"
    # 12:05 AM today is more than two hours past (it is 2:20 AM PDT).
    assert ResetTime.parse("12:05 AM", ~U[2026-09-18 09:20:37Z], @zone) == "2026-09-19T07:06:00Z"
  end

  test "a clock time that passed in the last two hours resumes now, not tomorrow" do
    # 6:40 PM PDT: a refusal that said 6:26 PM names the reset that just
    # passed. Rolling it to tomorrow would hold the ticket for a day.
    assert ResetTime.parse("6:26 PM", ~U[2026-09-22 01:40:00Z], @zone) == "2026-09-22T01:27:00Z"
    # 00:10 AM PDT: 11:50 PM was yesterday, twenty minutes ago.
    assert ResetTime.parse("11:50 PM", ~U[2026-09-22 07:10:00Z], @zone) == "2026-09-22T06:51:00Z"
  end

  test "a date without a year rolls into next year once passed" do
    assert ResetTime.parse("Jan 2nd 9:00 AM", ~U[2026-09-18 09:20:37Z], @zone) == "2027-01-02T17:01:00Z"
    assert ResetTime.parse("September 21 6:26 pm", ~U[2026-09-18 09:20:37Z], @zone) == "2026-09-22T01:27:00Z"
  end

  test "a date without a year that passed recently never jumps a year" do
    # "Sep 18th 1:00 AM" read later that day is this morning's reset, not
    # 2027's: a one-year hold for a reset that already happened.
    assert ResetTime.parse("Sep 18th 1:00 AM", ~U[2026-09-18 10:00:00Z], @zone) == "2026-09-18T08:01:00Z"
    assert ResetTime.parse("Sep 18th 1:00 AM", ~U[2026-09-19 06:00:00Z], @zone) == "2026-09-18T08:01:00Z"
    # "Dec 31st" read on New Year's Day is last year's date.
    assert ResetTime.parse("Dec 31st 11:00 PM", ~U[2027-01-01 09:00:00Z], @zone) == "2027-01-01T07:01:00Z"
    # Past the one-day bound, the next occurrence is next year's.
    assert ResetTime.parse("Sep 18th 1:00 AM", ~U[2026-09-20 10:00:00Z], @zone) == "2027-09-18T08:01:00Z"
  end

  test "DST gaps and overlaps resolve to the later instant" do
    assert ResetTime.parse("Mar 8th, 2026 2:30 AM", ~U[2026-03-01 00:00:00Z], @zone) == "2026-03-08T10:01:00Z"
    assert ResetTime.parse("Nov 1st, 2026 1:30 AM", ~U[2026-10-01 00:00:00Z], @zone) == "2026-11-01T09:31:00Z"
  end

  test "the host local zone is the default" do
    hint = "Sep 21st, 2026 6:26 PM"
    assert {:ok, reset, 0} = DateTime.from_iso8601(ResetTime.parse(hint, ~U[2026-09-18 09:20:37Z]))

    {{2026, 9, 21}, {18, 27, 0}} =
      reset |> DateTime.to_naive() |> NaiveDateTime.to_erl() |> :calendar.universal_time_to_local_time()
  end

  test "Codex pauses read the reset in the session's zone, not always the host's" do
    banner = "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 21st, 2026 6:26 PM."
    error = %{"message" => banner, "codexErrorInfo" => "usageLimitExceeded"}
    opts = [now: ~U[2026-09-18 09:20:37Z], zone: "Etc/UTC"]

    notification = %{"method" => "error", "params" => %{"error" => error, "willRetry" => false}}
    assert NotificationPolicy.usage_limit_pause(notification, "error", opts).reset_at == "2026-09-21T18:27:00Z"

    completed = %{"method" => "turn/completed", "params" => %{"turn" => %{"id" => "t", "status" => "failed", "error" => error}}}
    assert {:paused, %{reset_at: "2026-09-21T18:27:00Z"}} = NotificationPolicy.turn_usage_limit_pause(completed, opts)

    session = %{clock: fn -> ~U[2026-09-18 09:20:37Z] end, reset_time_zone: "Asia/Tokyo"}
    assert {:paused, %{reset_at: "2026-09-21T09:27:00Z"}} = NotificationPolicy.turn_usage_limit_pause(completed, NotificationPolicy.reset_opts(session))

    # The exhausted window's numeric resetsAt wins over the text in any zone.
    numeric = Keyword.put(opts, :numeric_reset, ~U[2026-09-22 01:26:25Z])
    assert NotificationPolicy.usage_limit_pause(notification, "error", numeric).reset_at == "2026-09-22T01:26:25Z"
    assert {:paused, %{reset_at: "2026-09-22T01:26:25Z"}} = NotificationPolicy.turn_usage_limit_pause(completed, numeric)
  end

  test "the numeric reset is the latest future resetsAt of a used-up window" do
    {:ok, port} = open_port()
    session = %{port: port, clock: fn -> ~U[2026-09-18 09:20:37Z] end, reset_time_zone: @zone}
    now = ~U[2026-09-18 09:20:37Z]
    on_exit(fn -> ExhaustedReset.clear(session) end)

    assert ExhaustedReset.latest(session, now) == nil

    ExhaustedReset.observe(session, %{"primary" => %{"usedPercent" => 100, "resetsAt" => 1_790_040_385}, "secondary" => %{"usedPercent" => 40, "resetsAt" => 1_790_900_000}})
    assert ExhaustedReset.latest(session, now) == ~U[2026-09-22 01:26:25Z]
    assert NotificationPolicy.reset_opts(session)[:numeric_reset] == ~U[2026-09-22 01:26:25Z]

    # A patch with no window facts keeps it; a reset already past is ignored.
    ExhaustedReset.observe(session, %{"planType" => "pro"})
    assert ExhaustedReset.latest(session, now) == ~U[2026-09-22 01:26:25Z]
    assert ExhaustedReset.latest(session, ~U[2026-09-22 01:26:25Z]) == nil

    # A read response with several limit sets keeps each set's exhausted window.
    ExhaustedReset.observe_snapshot(session, %{
      "rateLimits" => %{"primary" => %{"usedPercent" => 10}},
      "rateLimitsByLimitId" => %{
        "codex" => %{"primary" => %{"usedPercent" => 100, "resetsAt" => 1_790_040_385}},
        "gpt-5" => %{"secondary" => %{"usedPercent" => 100, "resetsAt" => 1_790_050_000}}
      }
    })

    assert ExhaustedReset.latest(session, now) == DateTime.from_unix!(1_790_050_000)

    # The window is no longer used up: the numeric reset is gone.
    ExhaustedReset.observe(session, %{"limitId" => "gpt-5", "secondary" => %{"usedPercent" => 20, "resetsAt" => 1_790_050_000}})
    assert ExhaustedReset.latest(session, now) == ~U[2026-09-22 01:26:25Z]
    ExhaustedReset.observe(session, %{"limitId" => "codex", "primary" => %{"usedPercent" => 99, "resetsAt" => 1_790_040_385}})
    ExhaustedReset.observe(session, %{"primary" => %{"usedPercent" => 99}})
    assert ExhaustedReset.latest(session, now) == nil

    ExhaustedReset.observe(session, %{"primary" => %{"usedPercent" => 100, "resetsAt" => 1_790_040_385}})
    ExhaustedReset.clear(session)
    assert ExhaustedReset.latest(session, now) == nil
    assert ExhaustedReset.latest(%{}, now) == nil
  end

  test "agent.codex.reset_time_zone accepts an IANA zone and rejects anything else" do
    assert {:ok, settings} = Schema.parse(%{"agent" => %{"codex" => %{"reset_time_zone" => "America/Los_Angeles"}}})
    assert settings.agent.codex.reset_time_zone == "America/Los_Angeles"
    assert {:ok, default} = Schema.parse(%{})
    assert default.agent.codex.reset_time_zone == nil
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"agent" => %{"codex" => %{"reset_time_zone" => "Pacific Time"}}})
    assert message =~ "reset_time_zone"
  end

  defp open_port do
    port = Port.open({:spawn, "cat"}, [:binary])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    {:ok, port}
  end

  test "past, invalid and unknown hints stay unknown" do
    now = ~U[2026-09-18 09:20:37Z]

    for hint <- [
          nil,
          "",
          "soon",
          "Sep 17th, 2026 6:26 PM",
          "Foo 21st, 2026 6:26 PM",
          "Feb 30th, 2026 6:26 PM",
          "13:26 PM",
          "6:61 PM",
          "2026-09-18T09:00:00Z"
        ] do
      assert ResetTime.parse(hint, now, @zone) == nil
    end

    assert ResetTime.parse("Sep 21st, 2026 6:26 PM", now, "Unknown/Zone") == nil
    assert ResetTime.parse("2026-09-22T01:26:25Z", now, @zone) == "2026-09-22T01:26:25Z"
  end
end
