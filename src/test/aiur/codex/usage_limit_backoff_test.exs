defmodule Aiur.Codex.UsageLimitBackoffTest do
  # #2737 review: a Codex refusal whose text reset already passed (a remote
  # worker in another zone, or Codex still refusing just after its printed
  # reset) resumed on the next tick, met the same refusal and resumed again.
  use ExUnit.Case, async: true

  alias Aiur.Codex.{ExhaustedReset, NotificationPolicy}
  alias Aiur.ModelAvailability
  alias Aiur.Orchestrator.RateLimitFallback

  @banner "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 6:26 PM."
  # 6:26 PM PDT is 01:26Z; rounded up to the end of the minute it is 01:27Z,
  # 13 minutes before the refusal.
  @refused_at ~U[2026-09-22 01:40:00Z]
  @zone "America/Los_Angeles"

  setup do
    path = Aiur.TestSupport.tmp_root!("aiur-usage-limit-backoff") <> ".json"
    on_exit(fn -> File.rm(path) end)

    issue = %Aiur.Issue{id: "15", identifier: "15", title: "KHA-106", state: "In Progress", selected_backend: "codex"}
    %{path: path, issue: issue}
  end

  test "a refusal whose text reset already passed waits the minimum delay", %{path: path, issue: issue} do
    # The reviewer's probe: the same text at 01:40Z, 30s, 60s and 3600s later.
    for offset <- [0, 30, 60, 3600] do
      now = DateTime.add(@refused_at, offset)
      pause = refuse(now)
      assert pause.reset_at == iso(DateTime.add(now, 300))
      refute decide(issue, pause, path, now) == :resume
    end
  end

  test "a second refusal with the same past text does not resume inside the delay", %{path: path, issue: issue} do
    first = refuse(@refused_at, path)
    assert first.reset_at == iso(DateTime.add(@refused_at, 300))
    assert decide(issue, first, path, @refused_at) == :noop
    assert decide(issue, first, path, DateTime.add(@refused_at, 299)) == :noop
    assert decide(issue, first, path, DateTime.add(@refused_at, 300)) == :resume

    # Resumed at 01:45Z, Codex refuses again with the same text.
    again_at = DateTime.add(@refused_at, 300)
    second = refuse(again_at, path)
    assert second.reset_at == iso(DateTime.add(again_at, 300))
    assert decide(issue, second, path, again_at) == :noop
    assert decide(issue, second, path, DateTime.add(again_at, 300)) == :noop
  end

  test "the minimum delay is configurable", %{path: path, issue: issue} do
    pause = refuse(@refused_at, path, min_delay_seconds: 60)
    assert pause.reset_at == iso(DateTime.add(@refused_at, 60))
    assert decide(issue, pause, path, DateTime.add(@refused_at, 59)) == :noop
    assert decide(issue, pause, path, DateTime.add(@refused_at, 60)) == :resume
  end

  test "repeated refusals back off exponentially up to one hour", %{path: path, issue: issue} do
    # Each refusal comes at the moment the worker resumed from the last one,
    # and its text reset is already past, so it reads now plus 300 seconds.
    # (Past 03:26Z the clock text would roll to tomorrow, so the pause is
    # built with that clamped reset directly.)
    final_at =
      Enum.reduce([300, 600, 1200, 2400, 3600, 3600], @refused_at, fn hold, now ->
        pause = %{reset_at: iso(DateTime.add(now, 300))}
        assert :ok = ModelAvailability.mark_limited("codex", pause.reset_at, path: path, now: now)
        assert decide(issue, pause, path, DateTime.add(now, hold - 1)) == :noop, "hold #{hold}s ended early"
        assert decide(issue, pause, path, DateTime.add(now, hold)) == :resume, "hold #{hold}s did not end"
        DateTime.add(now, hold)
      end)

    assert get_in(ModelAvailability.load(path), ["backends", "codex", "limit_streak"]) == 6

    # A refusal long after the last one starts a new streak.
    later = DateTime.add(final_at, 3 * 3600)
    assert :ok = ModelAvailability.mark_limited("codex", iso(DateTime.add(later, 300)), path: path, now: later)
    assert %{"limit_streak" => 1} = entry = get_in(ModelAvailability.load(path), ["backends", "codex"])
    refute Map.has_key?(entry, "backoff_until")
    assert ModelAvailability.available?("codex", path: path, now: DateTime.add(later, 300))
  end

  test "a future numeric reset is unchanged", %{path: path, issue: issue} do
    numeric = DateTime.add(@refused_at, 3 * 3600 + 25)
    pause = refuse(@refused_at, path, numeric_reset: numeric)
    assert pause.reset_at == iso(numeric)
    assert get_in(ModelAvailability.load(path), ["backends", "codex", "reset_at"]) == iso(numeric)
    assert decide(issue, pause, path, DateTime.add(numeric, -1)) == :noop
    assert decide(issue, pause, path, numeric) == :resume
  end

  test "a refusal with no reset does not inherit a reset that passed", %{path: path} do
    # An old limit whose reset passed a minute ago, then a fresh limit with no
    # reset, far enough apart that no backoff hides the stale reset.
    old_at = DateTime.add(@refused_at, -3 * 3600)
    assert :ok = ModelAvailability.mark_limited("codex", iso(DateTime.add(@refused_at, -60)), path: path, now: old_at)
    assert :ok = ModelAvailability.mark_limited("codex", nil, path: path, now: @refused_at)
    assert get_in(ModelAvailability.load(path), ["backends", "codex", "limit_streak"]) == 1
    refute ModelAvailability.available?("codex", path: path, now: DateTime.add(@refused_at, 1))
  end

  test "a bare rate-limit update replaces the snapshot's codex window" do
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    session = %{port: port}
    epoch = DateTime.to_unix(@refused_at) + 3600

    snapshot = %{"rateLimitsByLimitId" => %{"codex" => %{"primary" => %{"usedPercent" => 100, "resetsAt" => epoch}}}}
    assert :ok = ExhaustedReset.observe_snapshot(session, snapshot)
    assert ExhaustedReset.latest(session, @refused_at) == DateTime.from_unix!(epoch)

    assert :ok = ExhaustedReset.observe(session, %{"primary" => %{"usedPercent" => 40, "resetsAt" => epoch}})
    assert ExhaustedReset.latest(session, @refused_at) == nil
  end

  # One refusal: the pause payload as Codex's failed turn/completed produces
  # it, recorded in the ledger the way TurnAlerts records it.
  defp refuse(now, path \\ nil, opts \\ []) do
    payload = %{"params" => %{"turn" => %{"status" => "failed", "error" => %{"message" => @banner, "codexErrorInfo" => "usageLimitExceeded"}}}}
    opts = Keyword.merge([now: now, zone: @zone, min_delay_seconds: 300, numeric_reset: nil], opts)
    assert {:paused, pause} = NotificationPolicy.turn_usage_limit_pause(payload, opts)
    assert pause.reset_hint == "6:26 PM"
    if path, do: assert(:ok = ModelAvailability.mark_limited("codex", pause.reset_at, path: path, now: now))
    pause
  end

  defp decide(issue, pause, path, now) do
    entry = %{
      issue: issue,
      identifier: issue.identifier,
      paused_reason: :usage_limit_exhausted,
      usage_limit_reset_at: pause.reset_at,
      control: %{status: :paused, can_interrupt: true}
    }

    state = if path, do: ModelAvailability.load(path), else: %{"backends" => %{}}

    RateLimitFallback.decide(entry, issue,
      primary_backend: "codex",
      fallback_backend: nil,
      current_backend: "codex",
      marker_label: "agent:rate-limit-fallback",
      state: state,
      now: now
    )
  end

  defp iso(time), do: DateTime.to_iso8601(time)
end
