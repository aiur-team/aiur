defmodule Aiur.CodingAgent.UsageFloorGateTest do
  use ExUnit.Case, async: false

  alias Aiur.CodingAgent.UsageFloorGate

  @now ~U[2026-11-06 09:00:00Z]

  setup do
    UsageFloorGate.reset()
    on_exit(&UsageFloorGate.reset/0)
    :ok
  end

  # Serial: the gate records held routes in `:persistent_term`, which is one
  # table for the whole VM, so this module must not share a run with others
  # that record floor state.

  # A settings-shaped floor reader: five percent for claude, two for codex.
  defp floor_fun do
    fn
      "claude" -> 5
      "codex" -> 2
      _backend -> 5
    end
  end

  defp candidates(backend, accounts) do
    Enum.map(accounts, &%{backend: backend, account: &1, route: backend <> ":model"})
  end

  defp readings(by_account) do
    Map.new(by_account, fn {account, used} -> {{"claude", account}, %{windows: used}} end)
  end

  defp opts(overrides \\ []) do
    Keyword.merge([usage_floor_percent_fun: floor_fun(), now: fn -> @now end], overrides)
  end

  describe "split_candidates/3" do
    test "keeps a candidate just above the floor and holds one at it" do
      candidates = candidates("claude", ["full", "nearly"])

      {allowed, held} =
        UsageFloorGate.split_candidates(
          candidates,
          readings(%{"full" => %{"seven_day" => 40}, "nearly" => %{"seven_day" => 95}}),
          opts()
        )

      assert Enum.map(allowed, & &1.account) == ["full"]
      assert [%{candidate: %{account: "nearly"}, held: held_window}] = held
      assert held_window.remaining_percent == 5.0
      assert UsageFloorGate.label(%{backend: "claude", account: "nearly"}) == "claude/nearly"
    end

    test "an unknown candidate is allowed" do
      candidates = candidates("claude", ["unobserved"])

      assert {[%{account: "unobserved"}], []} = UsageFloorGate.split_candidates(candidates, %{}, opts())
    end

    test "the per-backend floor applies to its own backend only" do
      candidates = candidates("codex", ["only"])
      reading = %{{"codex", "only"} => %{windows: %{"weekly" => 98}}}

      # 2% left, the codex floor, so 2 <= 2 floors it.
      assert {[], [%{held: %{floor_percent: 2}}]} = UsageFloorGate.split_candidates(candidates, reading, opts())

      claude_candidates = candidates("claude", ["only"])
      claude_reading = %{{"claude", "only"} => %{windows: %{"weekly" => 98}}}

      # The same reading under the claude floor (5) is held as well.
      assert {[], [%{held: %{floor_percent: 5}}]} = UsageFloorGate.split_candidates(claude_candidates, claude_reading, opts())
    end
  end

  describe "allowed_routes/2" do
    test "a route survives while one of its accounts is above the floor" do
      routes = ["claude:sonnet"]

      {allowed, _held} =
        UsageFloorGate.split_candidates(
          candidates("claude", ["busy", "free"]),
          readings(%{"busy" => %{"seven_day" => 99}, "free" => %{"seven_day" => 10}}),
          opts()
        )

      assert length(allowed) == 1
      assert UsageFloorGate.allowed_routes(routes, route_opts(%{"busy" => %{"seven_day" => 99}, "free" => %{"seven_day" => 10}})) == routes
    end

    test "a route whose every account is floored is dropped" do
      opts = route_opts(%{"busy" => %{"seven_day" => 99}})
      assert UsageFloorGate.allowed_routes(["claude:sonnet"], opts) == []
      assert UsageFloorGate.route_floored?("claude:sonnet", opts)
      assert UsageFloorGate.backend_floored?("claude", opts)
    end

    test "the floor does not hold a route that is not configured for accounts" do
      # No configured accounts: one implicit account with no reading at all.
      opts = [usage_floor_percent_fun: floor_fun(), accounts: %{}, account_list_fun: fn _ -> [] end, usage_snapshot: fn _b, _n -> %{} end, state: %{"backends" => %{}}]
      assert UsageFloorGate.allowed_routes(["claude:sonnet"], opts) == ["claude:sonnet"]
    end
  end

  describe "filter_routes/2" do
    test "records the hold and its recovery so priority and balance alert like headroom" do
      routes = ["claude:model"]
      held_opts = route_opts(%{"busy" => %{"seven_day" => 99}}) |> Keyword.put(:usage_floor_alert_fun, alert_fun())

      assert UsageFloorGate.filter_routes(routes, held_opts) == []
      assert_received {:alert, "system.agent.usage_floor.claude-busy", message, _opts_alert}
      assert message =~ "claude/busy held: 1% left ≤ 5% floor"
      assert Map.has_key?(UsageFloorGate.held_state(), "claude/busy")

      healthy_opts = route_opts(%{"busy" => %{"seven_day" => 40}}) |> Keyword.put(:usage_floor_alert_fun, alert_fun())

      assert UsageFloorGate.filter_routes(routes, healthy_opts) == routes
      assert_received {:alert, "system.agent.usage_floor.claude-busy.resolved", _message, _opts_alert}
      refute Map.has_key?(UsageFloorGate.held_state(), "claude/busy")
    end

    test "allowed_routes/2 stays a read and records nothing" do
      opts = route_opts(%{"busy" => %{"seven_day" => 99}}) |> Keyword.put(:usage_floor_alert_fun, alert_fun())

      assert UsageFloorGate.allowed_routes(["claude:model"], opts) == []
      refute_received {:alert, _, _, _}
      assert UsageFloorGate.held_state() == %{}
    end
  end

  describe "record/3" do
    test "alerts once when a route is floored and once when it recovers" do
      held = [%{candidate: %{backend: "claude", account: "everdred", route: "claude:sonnet"}, held: held_window()}]

      UsageFloorGate.record(held, ["claude/everdred"], opts(usage_floor_alert_fun: alert_fun()))

      assert_received {:alert, "system.agent.usage_floor.claude-everdred", message, opts_alert}
      assert message =~ "claude/everdred held: 3% left ≤ 5% floor"
      assert opts_alert[:needs_attention] == false
      assert Map.has_key?(UsageFloorGate.held_state(), "claude/everdred")

      # The same held set records nothing new.
      UsageFloorGate.record(held, ["claude/everdred"], opts(usage_floor_alert_fun: alert_fun()))
      refute_received {:alert, _, _, _}

      # Recovery: the candidate was evaluated and is no longer held.
      UsageFloorGate.record([], ["claude/everdred"], opts(usage_floor_alert_fun: alert_fun()))
      assert_received {:alert, "system.agent.usage_floor.claude-everdred.resolved", _message, _opts_alert}
      refute Map.has_key?(UsageFloorGate.held_state(), "claude/everdred")
    end

    test "a candidate that was simply not evaluated is neither recovered nor dropped" do
      held = [%{candidate: %{backend: "claude", account: "everdred", route: "claude:sonnet"}, held: held_window()}]
      UsageFloorGate.record(held, ["claude/everdred"], opts(usage_floor_alert_fun: alert_fun()))
      assert_received {:alert, "system.agent.usage_floor.claude-everdred", _message, _opts}

      UsageFloorGate.record([], ["codex/gpt"], opts(usage_floor_alert_fun: alert_fun()))

      refute_received {:alert, _, _, _}
      assert Map.has_key?(UsageFloorGate.held_state(), "claude/everdred")
    end
  end

  describe "hold_reason/2" do
    test "names every held route when the whole list is floored" do
      reason = UsageFloorGate.hold_reason(["claude:sonnet"], route_opts(%{"busy" => %{"seven_day" => 99}}))
      assert reason =~ "every route is held at the usage floor"
      assert reason =~ "claude/busy held: 1% left ≤ 5% floor"
    end

    test "is nil while a route can still be dispatched" do
      assert UsageFloorGate.hold_reason(["claude:sonnet"], route_opts(%{"busy" => %{"seven_day" => 40}})) == nil
    end
  end

  describe "held_lines/1" do
    test "renders one held line per floored candidate and nothing for a healthy route" do
      assert UsageFloorGate.held_lines(route_opts(%{"busy" => %{"seven_day" => 97}})) == ["claude/busy held: 3% left ≤ 5% floor"]
      assert UsageFloorGate.held_lines(route_opts(%{"busy" => %{"seven_day" => 40}})) == []
    end
  end

  describe "account_floored?/3" do
    test "reads the session options' usage map" do
      assert UsageFloorGate.account_floored?("claude", %{"seven_day" => 97}, opts())
      refute UsageFloorGate.account_floored?("claude", %{"seven_day" => 40}, opts())
      refute UsageFloorGate.account_floored?("claude", nil, opts())
    end
  end

  describe "credit_reading/2" do
    test "uses remaining credit against a known limit" do
      reading = UsageFloorGate.credit_reading("openrouter", provider_view_fun: fn :openrouter -> observed_view(%{"credits-remaining" => %{kind: :credit, used_percent: 96}}) end)

      assert reading.windows == %{"credits" => 96}
      assert UsageFloorGate.account_floored?("openrouter", reading, opts())
    end

    test "a key without a known limit is never floored" do
      assert UsageFloorGate.credit_reading("openrouter", provider_view_fun: fn :openrouter -> observed_view(%{"credits-remaining" => %{kind: :credit}}) end) == nil
    end

    # #7879: a $0 balance on a key with no known limit, with the floor off.
    test "a spent balance holds the route even without a known limit or a floor" do
      exhausted = %{"credits-remaining" => %{kind: :credit, remaining: 0, credits: %{status: :exhausted, amount: 0}}}
      candidate = %{backend: "openrouter", account: nil, route: "openrouter"}

      gate_opts =
        opts(
          usage_floor_percent_fun: fn _backend -> 0 end,
          provider_view_fun: fn :openrouter -> observed_view(exhausted) end
        )

      assert {[], [%{candidate: ^candidate, held: %{remaining_percent: +0.0}}]} = UsageFloorGate.split_candidates([candidate], %{}, gate_opts)
    end

    test "a stale spent balance does not hold the route" do
      exhausted = %{"credits-remaining" => %{kind: :credit, remaining: 0, credits: %{status: :exhausted, amount: 0}}}
      candidate = %{backend: "openrouter", account: nil, route: "openrouter"}
      stale = fn :openrouter -> %{observed_view(exhausted) | freshness: :stale} end

      assert {[^candidate], []} = UsageFloorGate.split_candidates([candidate], %{}, opts(provider_view_fun: stale))
    end

    test "an unobserved provider has no reading" do
      assert UsageFloorGate.credit_reading("openrouter", provider_view_fun: fn :openrouter -> %{state: :unknown} end) == nil
    end
  end

  defp alert_fun do
    test = self()
    fn topic, message, opts -> send(test, {:alert, topic, message, opts}) end
  end

  defp observed_view(windows) do
    %{state: :observed, windows: windows, freshness: :fresh, age_seconds: 30}
  end

  defp held_window do
    %{window: "seven_day", used_percent: 97, remaining_percent: 3.0, floor_percent: 5, resets_at: nil, age_seconds: nil, source: "meter"}
  end

  defp route_opts(by_account) do
    [
      usage_floor_percent_fun: floor_fun(),
      now: @now,
      routes: ["claude:model"],
      accounts: %{"claude" => Map.keys(by_account)},
      account_list_fun: fn "claude" -> Enum.map(Map.keys(by_account), &%{name: &1}) end,
      account_capability_fun: fn "claude" -> {:ok, %{supported: true, multi: :available}} end,
      usage_snapshot: fn "claude", names ->
        for name <- names, Map.has_key?(by_account, name), into: %{} do
          {name, %{reading: %{windows: windows_list(Map.fetch!(by_account, name))}, observed_at: @now, freshness: :fresh}}
        end
      end,
      state: %{"backends" => %{}},
      path: Path.join(Aiur.TestSupport.tmp_root!("usage-floor-gate"), "model-usage.json")
    ]
  end

  defp windows_list(by_window), do: Enum.map(by_window, fn {window, used} -> %{window: window, used_percent: used} end)
end
