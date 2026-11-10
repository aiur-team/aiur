Code.require_file("fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.RateLimitFallback.PolicyTargetTest do
  @moduledoc """
  A paused claim moves to the next source the capacity policy allows (#7891,
  plan `2026-11-08-7881-provider-capacity-policy.md` PCP-6).
  """

  use Aiur.TestSupport

  import Aiur.RateLimitFallbackFixture, only: [fallback_entry: 1, record_started_dispatch: 2]

  alias Aiur.Accounts.UsageReadings
  alias Aiur.Orchestrator.{RateLimitFallback, Slots, State, StatusReason}
  alias Aiur.Orchestrator.StatusReport.UsagePauseBackends

  @now ~U[2026-11-10 12:00:00Z]
  @priority ["codex", "claude", "openrouter"]

  # Keep 30% of Claude for Executors; OpenRouter is the last resort with a daily cap.
  @policy %{
    sources: %{
      "claude" => %{billing: "subscription", reserve: %{percent: 30, accounts: ["default"]}},
      "codex" => %{billing: "subscription"},
      "openrouter" => %{billing: "prepaid", last_resort: true, limits: %{daily_usd: 5}}
    }
  }

  setup do
    UsageReadings.reset()
    on_exit(&UsageReadings.reset/0)
    :ok
  end

  describe "a claim paused at any priority position" do
    test "on the primary, a fallback held by its reserve is skipped for the next allowed source" do
      assert_moves("codex", "openrouter", claude_used: 75)
      assert_receive {:label, "model:openrouter"}
    end

    test "on the primary, the configured fallback is used while the policy allows it" do
      assert_moves("codex", "claude", claude_used: 10)
    end

    test "in the middle of the priority list, it moves on to the next allowed source" do
      assert_moves("claude", "openrouter", claude_used: 75)
    end

    test "last in the priority list, it moves back to an earlier allowed source" do
      assert_moves("openrouter", "claude", claude_used: 10)
    end

    test "the last-resort source is not chosen while another source is allowed" do
      assert_moves("codex", "claude", claude_used: 10, fallback_backend: "openrouter")
    end
  end

  describe "a held target" do
    test "a reserved account at or below its reserve is never targeted" do
      refute_moves("openrouter", claude_used: 70)
    end

    test "a source past its limit is never targeted" do
      refute_moves("claude", claude_used: 75, capacity_spend: %{"openrouter" => %{daily_usd: 5}})
    end

    test "with no allowed target the claim keeps no slot and its status names each hold" do
      opts = opts(claude_used: 75, capacity_spend: %{"openrouter" => %{daily_usd: 6}})
      result = RateLimitFallback.reconcile(state("codex"), opts)

      refute_received {:dispatch, _backend}
      assert result.running["1"].paused_reason == :usage_limit_exhausted
      assert Slots.available_slots(result) == 2

      backends = UsagePauseBackends.for_running(result.running, opts)
      reason = UsagePauseBackends.pause_reason(:usage_limit_exhausted, backends)
      assert StatusReason.render(reason) == "provider limit; codex limited, claude held: reserve, openrouter held: limit daily"
    end
  end

  defp assert_moves(from, to, overrides) do
    RateLimitFallback.reconcile(state(from), opts(overrides))
    assert_receive {:dispatch, ^to}
  end

  defp refute_moves(from, overrides) do
    RateLimitFallback.reconcile(state(from), opts(overrides))
    refute_received {:dispatch, _backend}
  end

  defp state(backend) do
    entry =
      fallback_entry(%{
        issue: %Issue{id: "1", identifier: "repo#1", labels: [], selected_backend: backend},
        worker_host: nil,
        paused_at: DateTime.add(@now, -601, :second),
        session_execution: %{backend: backend}
      })

    %State{max_concurrent_agents: 2, running: %{"1" => entry}}
  end

  # Codex is limited in the ledger; Claude/default has `claude_used` percent of its week spent.
  defp opts(overrides) do
    {used, overrides} = Keyword.pop!(overrides, :claude_used)
    ledger_path = Path.join(Aiur.TestSupport.tmp_root!("policy-target-ledger"), "model-usage.json")
    File.mkdir_p!(Path.dirname(ledger_path))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(Path.dirname(ledger_path)) end)
    test_pid = self()

    Keyword.merge(
      [
        now: @now,
        fallback_backend: "claude",
        primary_backend: "codex",
        marker_label: "agent:rate-limit-fallback",
        routing_backend: nil,
        priority_backends: @priority,
        state: %{"backends" => %{"codex" => %{"limited" => true, "reset_at" => "2999-01-01T00:00:00Z"}}},
        path: ledger_path,
        capacity_policy: @policy,
        capacity_spend: %{"openrouter" => %{daily_usd: 0}},
        account_selection: "headroom",
        accounts: %{"claude" => ["default"]},
        account_list_fun: fn
          "claude" -> [%{name: "default"}]
          _harness -> []
        end,
        account_capability_fun: fn
          "claude" -> {:ok, %{supported: true, multi: :available}}
          _harness -> {:error, :unsupported_account_backend}
        end,
        api_key_fetcher: fn _env -> "test-key" end,
        provider_view_fun: fn _provider -> nil end,
        usage_floor_percent_fun: fn _backend -> 5 end,
        usage_snapshot: claude_meter(used),
        probe_fun: fn _backend, _options -> :ok end,
        backend_ready_fun: fn _backend, _worker_host -> true end,
        dispatch_ready_fun: fn state, _issue, _worker_host -> {:ok, state} end,
        teardown_fun: fn current_state, _entry, _reason -> current_state end,
        add_label_fun: fn _identifier, label -> send(test_pid, {:label, label}) && :ok end,
        dispatch_fun: fn current_state, issue, _attempt, _worker_host ->
          send(test_pid, {:dispatch, issue.selected_backend})
          record_started_dispatch(current_state, issue)
        end
      ],
      overrides
    )
  end

  defp claude_meter(used) do
    fn
      "claude", names ->
        for "default" = name <- names, into: %{} do
          {name, %{reading: %{windows: [%{window: "seven_day", used_percent: used}]}, observed_at: @now, freshness: :fresh}}
        end

      _harness, _names ->
        %{}
    end
  end
end
