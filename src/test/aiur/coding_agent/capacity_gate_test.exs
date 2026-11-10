defmodule Aiur.CodingAgent.CapacityGateTest do
  @moduledoc """
  The capacity policy applied at dispatch (#7889, plan
  `2026-11-08-7881-provider-capacity-policy.md` §1 and §5): headroom selection,
  the `priority` chain, pins and the fleet provider gate.
  """

  use Aiur.TestSupport

  alias Aiur.Accounts.UsageReadings
  alias Aiur.CodingAgent
  alias Aiur.CodingAgent.CapacityGate
  alias Aiur.Config.{CapacityPolicy, Overrides}
  alias Aiur.Issue
  alias Aiur.Orchestrator.{DispatchPolicy, TelemetryCohort}

  @now ~U[2026-10-10 06:00:00Z]
  @future "2999-01-01T00:00:00Z"
  @backends ["codex", "claude", "openrouter"]

  # Codex is usage-limited in the ledger.
  @codex_limited %{"backends" => %{"codex" => %{"limited" => true, "reset_at" => @future}}}

  # The operator's stated policy: keep 30% of Claude for Executors, OpenRouter last.
  # OpenRouter's recorded spend has reached a $5 daily limit.
  @spent %{"openrouter" => %{daily_usd: 5.0}}
  @policy %{
    sources: %{
      "claude" => %{billing: "subscription", reserve: %{percent: 30, accounts: ["default"]}},
      "codex" => %{billing: "subscription"},
      "openrouter" => %{billing: "prepaid", last_resort: true}
    }
  }

  setup do
    UsageReadings.reset()
    on_exit(&UsageReadings.reset/0)
    :ok
  end

  # Claude/default's polled meter: `used` percent of its seven-day window.
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

  defp opts(overrides) do
    ledger_path = Path.join(Aiur.TestSupport.tmp_root!("capacity-gate-ledger"), "model-usage.json")
    File.mkdir_p!(Path.dirname(ledger_path))
    File.write!(ledger_path, Jason.encode!(%{"backends" => %{}}))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(Path.dirname(ledger_path)) end)

    Keyword.merge(
      [
        account_selection: "headroom",
        routing_candidates: %{},
        priority_backends: @backends,
        backends: @backends,
        configured_backends: @backends,
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
        # Claude/default has 25% left: below its 30% reserve.
        usage_snapshot: claude_meter(75),
        state: @codex_limited,
        path: ledger_path,
        probe_fun: fn _backend, _options -> :ok end,
        avoid_peak_pricing: false,
        capacity_policy: @policy,
        now: @now
      ],
      overrides
    )
  end

  defp ticket(labels \\ ["complexity:3"]), do: %Issue{id: "id-1", identifier: "T-1", labels: labels}

  defp verdict(issue, name), do: Enum.find(issue.dispatch_selection.candidates, &(&1.name == name))

  describe "headroom selection" do
    test "claude below its reserve and codex limited: dispatch goes to the last-resort source" do
      assert {:ok, %Issue{selected_backend: "openrouter"} = issue} = CodingAgent.select_for_dispatch(ticket(), opts([]))

      assert %{policy: "capacity/v1", chosen: %{route: "openrouter", reason: :last_resort_used}} = issue.dispatch_selection
      assert %{verdict: :hold, reason: :reserve, detail: "reading 25% left, reserve 30%"} = verdict(issue, "claude/default")
      assert %{reason: :limited, status: :exhausted} = verdict(issue, "codex")
      assert issue.dispatch_selection.summary =~ "claude/default hold: reserve"
      # The `dispatch` telemetry point carries the same reason.
      assert TelemetryCohort.dispatch_reason(issue) == :last_resort_used
    end

    test "the last-resort source is deferred while another source is allowed" do
      assert {:ok, %Issue{selected_backend: "claude", selected_account: "default"} = issue} =
               CodingAgent.select_for_dispatch(ticket(), opts(usage_snapshot: claude_meter(10)))

      assert %{reason: :only_allowed} = issue.dispatch_selection.chosen
      assert %{verdict: :defer, reason: :last_resort} = verdict(issue, "openrouter")
    end

    test "every source held: the claim waits instead of dispatching" do
      policy = put_in(@policy, [:sources, "openrouter", :limits], %{daily_usd: 5})

      assert {:all_limited, routes} = CodingAgent.select_for_dispatch(ticket(), opts(capacity_policy: policy, capacity_spend: @spent))
      assert "openrouter" in routes
    end

    test "a pin obeys the reserve" do
      assert {:all_limited, ["claude"]} = CodingAgent.select_for_dispatch(ticket(["model:claude"]), opts(state: %{"backends" => %{}}))

      assert {:ok, %Issue{selected_account: "default"} = issue} =
               CodingAgent.select_for_dispatch(ticket(["model:claude"]), opts(state: %{"backends" => %{}}, usage_snapshot: claude_meter(10)))

      assert %{reason: :pinned} = issue.dispatch_selection.chosen
    end
  end

  describe "priority chain" do
    test "claude below its reserve and codex limited: the chain takes the last-resort source" do
      assert {:ok, %Issue{selected_backend: "openrouter"}} = CodingAgent.select_for_dispatch(ticket([]), opts(account_selection: "priority"))
    end
  end

  describe "provider gate" do
    test "holds fleet admission when the policy allows no source, naming the cause" do
      policy = put_in(@policy, [:sources, "openrouter", :limits], %{daily_usd: 5})
      opts = opts(capacity_policy: policy, capacity_spend: @spent)

      assert DispatchPolicy.provider_gate(@backends, opts) == :hold
      assert DispatchPolicy.Gates.provider_hold_threshold(@backends, opts) == :no_authorized_source
      assert DispatchPolicy.provider_gate(@backends, opts(usage_snapshot: claude_meter(10), capacity_policy: policy, capacity_spend: @spent)) == :dispatch
    end

    test "dispatches when the last-resort source is the only one allowed" do
      assert DispatchPolicy.provider_gate(@backends, opts([])) == :dispatch
    end
  end

  describe "configured policy" do
    setup do
      home = Aiur.TestSupport.tmp_root!("capacity-gate-config")
      File.mkdir_p!(home)
      machine = Path.join(home, "machine")
      previous_machine = Application.get_env(:aiur, :machine_settings_path)
      previous_instance = System.get_env("AIUR_INSTANCE_KEY")
      Application.put_env(:aiur, :machine_settings_path, machine)
      System.put_env("AIUR_INSTANCE_KEY", "capacity-gate-#{System.unique_integer([:positive])}")
      {:ok, override_path} = Overrides.path()

      on_exit(fn ->
        if previous_machine, do: Application.put_env(:aiur, :machine_settings_path, previous_machine), else: Application.delete_env(:aiur, :machine_settings_path)
        if previous_instance, do: System.put_env("AIUR_INSTANCE_KEY", previous_instance), else: System.delete_env("AIUR_INSTANCE_KEY")
        :persistent_term.erase({Aiur.Machine.Settings, machine})
        :persistent_term.erase({CapacityGate, :last_error})
        Aiur.TestCleanup.rm_rf!(home)
        Aiur.TestCleanup.rm_rf!(Path.dirname(override_path))
      end)

      %{machine: machine}
    end

    defp machine_reserve!(path, percent) do
      File.write!(path, """
      capacity:
        sources:
          claude: { billing: subscription, reserve: { percent: #{percent}, accounts: [default] } }
          openrouter: { billing: prepaid, last_resort: true }
      """)
    end

    defp configured_opts, do: Keyword.delete(opts([]), :capacity_policy)

    test "the machine reserve holds claude without a :capacity_policy option", %{machine: machine} do
      machine_reserve!(machine, 30)

      assert {:ok, %Issue{selected_backend: "openrouter"} = issue} = CodingAgent.select_for_dispatch(ticket(), configured_opts())
      assert %{chosen: %{reason: :last_resort_used}} = issue.dispatch_selection
      assert %{verdict: :hold, reason: :reserve} = verdict(issue, "claude/default")
    end

    test "a machine reserve raised above the project value still holds", %{machine: machine} do
      machine_reserve!(machine, 5)
      workflow = Aiur.Workflow.workflow_file_path()
      write_workflow_file!(workflow)
      write_workflow_file_atomic!(workflow, File.read!(workflow) <> "capacity:\n  sources:\n    claude: { reserve: { percent: 5 } }\n")
      :ok = Aiur.WorkflowStore.force_reload(5_000)
      # The operator tightens the machine file after the project value was accepted.
      # A different file size defeats the settings cache within one mtime second.
      machine_reserve!(machine, 45)
      assert {:error, _loosens} = CapacityPolicy.effective()

      assert {:ok, %Issue{selected_backend: "openrouter"} = issue} = CodingAgent.select_for_dispatch(ticket(), configured_opts())
      assert %{verdict: :hold, reason: :reserve, detail: "reading 25% left, reserve 45%"} = verdict(issue, "claude/default")
    end
  end

  test "allowed_routes keeps two routes that share a backend" do
    routes = ["claude:sonnet", "claude:opus", "codex"]
    assert CapacityGate.allowed_routes(routes, opts(usage_snapshot: claude_meter(10), backends: routes)) == ["claude:sonnet", "claude:opus"]
  end
end
