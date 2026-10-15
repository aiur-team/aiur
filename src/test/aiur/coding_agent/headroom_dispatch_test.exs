defmodule Aiur.CodingAgent.HeadroomDispatchTest do
  use Aiur.TestSupport

  alias Aiur.Accounts
  alias Aiur.AgentRunner.{DispatchSelectionEvent, SessionLifecycle}
  alias Aiur.CodingAgent
  alias Aiur.CodingAgent.HeadroomDispatch
  alias Aiur.Config.Schema
  alias Aiur.Issue
  alias Aiur.ModelAvailability

  @now ~U[2026-10-10 06:00:00Z]
  @future "2999-01-01T00:00:00Z"

  # Codex: 5% left on its weekly window, read from the usage ledger.
  @ledger %{"backends" => %{"codex" => %{"observed_at" => "2026-10-10T05:59:30Z", "weekly" => %{"used" => 95, "limit" => 100, "reset_at" => @future}}}}

  defp meters(by_account) do
    fn
      "claude", names ->
        for name <- names, Map.has_key?(by_account, name), into: %{} do
          {seven_day, five_hour} = Map.fetch!(by_account, name)

          {name,
           %{
             reading: %{windows: [%{window: "seven_day", used_percent: seven_day}, %{window: "five_hour", used_percent: five_hour}]},
             observed_at: @now,
             freshness: :fresh
           }}
        end

      _harness, _names ->
        %{}
    end
  end

  # Claude/default 100% left, Claude/everdred 64% left.
  @healthy %{"default" => {0, 0}, "everdred" => {36, 10}}

  defp opts(overrides) do
    ledger_path = Path.join(Aiur.TestSupport.tmp_root!("headroom-ledger"), "model-usage.json")
    File.mkdir_p!(Path.dirname(ledger_path))
    File.write!(ledger_path, Jason.encode!(%{"backends" => %{}}))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(Path.dirname(ledger_path)) end)

    Keyword.merge(
      [
        account_selection: "headroom",
        routing_candidates: %{3 => ["claude:sonnet", "codex:gpt-5.5:high"]},
        priority_backends: ["claude", "codex"],
        backends: ["claude", "codex"],
        configured_backends: ["claude", "codex"],
        accounts: %{"claude" => ["default", "everdred"]},
        account_list_fun: fn
          "claude" -> [%{name: "default"}, %{name: "everdred"}]
          _harness -> []
        end,
        account_capability_fun: fn
          "claude" -> {:ok, %{supported: true, multi: :available}}
          _harness -> {:error, :unsupported_account_backend}
        end,
        usage_snapshot: meters(@healthy),
        state: @ledger,
        path: ledger_path,
        probe_fun: fn _backend, _options -> :ok end,
        avoid_peak_pricing: false,
        now: @now
      ],
      overrides
    )
  end

  defp ticket(labels \\ ["complexity:3"]), do: %Issue{id: "id-1", identifier: "T-1", labels: labels}

  defp select(issue \\ ticket(), overrides \\ []), do: CodingAgent.select_for_dispatch(issue, opts(overrides))

  describe "issue #3960 acceptance" do
    test "Codex 5%, Claude/default 100%, Claude/everdred 64%: a complexity-3 ticket picks Claude/default" do
      assert {:ok, %Issue{selected_backend: "claude", selected_account: "default", selected_model: "sonnet"} = issue} = select()

      assert issue.dispatch_selection.summary ==
               "headroom: claude/default=100%; alternatives claude/everdred=64%, codex=5%"

      assert [
               %{name: "claude/default", status: :known, remaining_percent: 100, source: "meter"},
               %{name: "claude/everdred", status: :known, remaining_percent: 64, binding_window: "seven_day"},
               %{name: "codex", status: :low, remaining_percent: 5, source: "ledger", route: "codex:gpt-5.5:high"}
             ] = issue.dispatch_selection.candidates
    end

    test "with Claude/default exhausted it picks Claude/everdred" do
      assert {:ok, %Issue{selected_backend: "claude", selected_account: "everdred"}} =
               select(ticket(), usage_snapshot: meters(%{"default" => {40, 100}, "everdred" => {36, 10}}))
    end

    test "with all Claude exhausted it picks Codex, and the Codex route's model and effort apply" do
      assert {:ok, %Issue{selected_backend: "codex", selected_account: nil} = issue} =
               select(ticket(), usage_snapshot: meters(%{"default" => {100, 0}, "everdred" => {12, 100}}))

      assert CodingAgent.backend_for(issue) == "codex"
      assert CodingAgent.model_for(issue) == "gpt-5.5"
      assert CodingAgent.effort_for(issue) == "high"
    end

    test "with a model:codex label it picks Codex regardless of headroom" do
      assert {:ok, issue} = select(ticket(["complexity:3", "model:codex"]))

      assert CodingAgent.backend_for(issue) == "codex"
      assert issue.selected_backend == nil
      assert issue.dispatch_selection.pinned
      assert issue.dispatch_selection.summary == "headroom: codex=5%"
    end

    test "an unknown-usage backend never beats a known backend with more than 10% left" do
      assert {:ok, %Issue{selected_backend: "claude", selected_account: "everdred"}} =
               select(ticket(), state: %{"backends" => %{}}, usage_snapshot: meters(%{"default" => {100, 0}, "everdred" => {89, 0}}))
    end

    test "unknown usage beats a known backend with 10% or less left" do
      assert {:ok, %Issue{selected_backend: "codex"} = issue} =
               select(ticket(), state: %{"backends" => %{}}, usage_snapshot: meters(%{"default" => {100, 0}, "everdred" => {95, 0}}))

      assert issue.dispatch_selection.summary =~ "headroom: codex=unknown"
    end

    test "every candidate exhausted parks the claim on the candidate routes" do
      limited = %{"backends" => %{"codex" => %{"limited" => true, "reset_at" => @future}}}

      assert {:all_limited, ["claude:sonnet", "codex:gpt-5.5:high"]} =
               select(ticket(), state: limited, usage_snapshot: meters(%{"default" => {100, 0}, "everdred" => {0, 100}}))
    end
  end

  describe "candidates" do
    test "a single-string routing level keeps its backend; headroom only picks the account" do
      assert {:ok, %Issue{selected_backend: "claude", selected_account: "everdred"}} =
               select(ticket(), routing_candidates: %{3 => ["claude:sonnet"]}, usage_snapshot: meters(%{"default" => {90, 0}, "everdred" => {36, 0}}))
    end

    test "a level with no routing entry uses agent.priority" do
      assert {:ok, %Issue{selected_backend: "codex"}} =
               select(ticket(["complexity:2"]), state: %{"backends" => %{}}, usage_snapshot: meters(%{"default" => {100, 0}, "everdred" => {100, 0}}))
    end

    test "a headroom choice is re-scored on the next dispatch; a rate-limit pin is not" do
      {:ok, first} = select()
      assert first.selected_backend == "claude"

      exhausted = meters(%{"default" => {100, 0}, "everdred" => {100, 0}})
      assert {:ok, %Issue{selected_backend: "codex"}} = select(first, usage_snapshot: exhausted)

      pinned = %Issue{ticket() | selected_backend: "claude"}
      assert {:ok, %Issue{selected_backend: "claude", dispatch_selection: %{pinned: true}}} = select(pinned, usage_snapshot: exhausted)
    end

    test "the policy is off unless account_selection is headroom" do
      refute HeadroomDispatch.enabled?(account_selection: "balance")
      assert {:ok, %Issue{dispatch_selection: nil}} = select(ticket(), account_selection: "balance")
    end

    test "backend_reading/2 ignores ledger windows whose reset has passed" do
      past = %{"backends" => %{"codex" => %{"weekly" => %{"used" => 95, "limit" => 100, "reset_at" => "2026-01-01T00:00:00Z"}}}}

      assert HeadroomDispatch.backend_reading("codex", state: past, now: @now) == nil

      assert HeadroomDispatch.backend_reading("codex", state: @ledger, now: @now, max_reading_age_seconds: 1800) ==
               %{windows: %{"weekly" => 95.0}, source: "ledger", age_seconds: 30}
    end

    test "stale Codex remains unknown until its probe refreshes it, then wins the next claim" do
      old = put_in(@ledger, ["backends", "codex", "observed_at"], "2026-10-07T06:00:00Z")
      path = Path.join(Aiur.TestSupport.tmp_root!("headroom-lock"), "model-usage.json")
      File.mkdir_p!(Path.dirname(path))
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(Path.dirname(path)) end)
      assert :ok = File.write(path, Jason.encode!(old))
      test_pid = self()

      probe = fn backend, options ->
        send(test_pid, {:probe, backend, options})
        :ok
      end

      claude_at_29 = meters(%{"default" => {71, 0}, "everdred" => {100, 0}})

      assert {:ok, %Issue{selected_backend: "claude", selected_account: "default"} = first} =
               select(ticket(), state: ModelAvailability.load(path), path: path, usage_snapshot: claude_at_29, probe_fun: probe)

      assert_receive {:probe, "codex", [path: _, now: @now]}, 100
      assert Enum.any?(first.dispatch_selection.candidates, &(&1.name == "codex" and &1.status == :unknown and &1.stale and &1.age_seconds == 259_200))

      assert :ok = ModelAvailability.observe("codex", %{"weekly" => %{"used" => 20, "limit" => 100, "reset_at" => @future}}, path: path, now: @now)
      assert :ok = ModelAvailability.clear_retry_schedule("codex", path: path)

      assert {:ok, %Issue{selected_backend: "codex"} = second} =
               select(ticket(), state: ModelAvailability.load(path), path: path, usage_snapshot: claude_at_29, probe_fun: probe)

      assert Enum.any?(second.dispatch_selection.candidates, &(&1.name == "codex" and &1.status == :known and &1.remaining_percent == 80))
    end

    test "a missing Codex observation does not bypass the probe retry window" do
      path = Path.join(Aiur.TestSupport.tmp_root!("headroom-probe-retry"), "model-usage.json")
      File.mkdir_p!(Path.dirname(path))
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(Path.dirname(path)) end)
      assert :ok = File.write(path, Jason.encode!(%{"backends" => %{}}))
      test_pid = self()

      probe = fn backend, _options ->
        send(test_pid, {:probe, backend})
        :ok
      end

      empty = %{"backends" => %{}}
      assert {:ok, _} = select(ticket(), state: empty, path: path, probe_fun: probe)
      assert_receive {:probe, "codex"}, 100

      within_retry_window = DateTime.add(@now, 119, :second)
      assert {:ok, _} = select(ticket(), state: ModelAvailability.load(path), path: path, now: within_retry_window, probe_fun: probe)
      refute_receive {:probe, "codex"}, 100
    end

    test "an old per-account meter reading is unknown and shows its age" do
      stale_meter = fn
        "claude", _names ->
          %{
            "default" => %{reading: %{windows: [%{window: "seven_day", used_percent: 0}]}, observed_at: DateTime.add(@now, -7_200, :second)},
            "everdred" => %{reading: %{windows: [%{window: "seven_day", used_percent: 50}]}, observed_at: DateTime.add(@now, -600, :second)}
          }

        _harness, _names ->
          %{}
      end

      assert {:ok, %Issue{selected_account: "everdred"} = issue} = select(ticket(), usage_snapshot: stale_meter, max_reading_age_seconds: 1800)
      assert issue.dispatch_selection.summary =~ "claude/everdred=50% (10m old)"
      assert issue.dispatch_selection.summary =~ "claude/default=unknown (stale, 2h old)"
    end
  end

  describe "config" do
    test "account_selection: headroom and list routing values parse; other readers see the first route" do
      assert {:ok, %{agent: agent}} =
               Schema.parse(%{
                 "agent" => %{
                   "priority" => ["claude", "codex"],
                   "account_selection" => "headroom",
                   "routing" => %{"3" => ["claude:sonnet", "codex:gpt-5.5:high"], "4" => "claude:opus"}
                 }
               })

      assert agent.account_selection == "headroom"
      assert agent.routing == %{3 => "claude:sonnet", 4 => "claude:opus"}
      assert agent.routing_candidates == %{3 => ["claude:sonnet", "codex:gpt-5.5:high"], 4 => ["claude:opus"]}

      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"agent" => %{"priority" => ["claude"], "routing" => %{"3" => "claude:sonnet:medium"}}})

      assert message =~ "accepts no effort segment"
    end
  end

  describe "explanation" do
    test "the dispatch selection is written to the ticket's agent event stream" do
      workspace = Aiur.TestSupport.tmp_root!("headroom-event")
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)
      {:ok, issue} = select()

      assert :ok = DispatchSelectionEvent.write(workspace, nil, issue)

      [line] = workspace |> Path.join("logs/agent.ndjson") |> File.read!() |> String.split("\n", trim: true)
      event = Jason.decode!(line)
      assert event["event"] == "dispatch_selection"
      assert event["account"] == "default"
      assert Enum.map(event["candidates"], & &1["name"]) == ["claude/default", "claude/everdred", "codex"]
      assert :ok = DispatchSelectionEvent.write(workspace, nil, ticket())
    end
  end

  describe "session account" do
    setup do
      home = Aiur.TestSupport.tmp_root!("headroom-accounts")
      previous = System.get_env("HOME")
      System.put_env("HOME", home)

      on_exit(fn ->
        if previous, do: System.put_env("HOME", previous), else: System.delete_env("HOME")
        Aiur.TestCleanup.rm_rf!(home)
      end)

      %{home: home}
    end

    test "the session runs on the account headroom chose and reports why", %{home: home} do
      :ok = Accounts.register("codex", "work", nil)

      issue = %Issue{
        id: "headroom-codex",
        identifier: "HR-1",
        selected_backend: "codex",
        selected_account: "work",
        dispatch_selection: %{backend: "codex", account: "work", route: "codex", pinned: false, summary: "headroom: codex/work=80%"}
      }

      {"codex", false, opts} =
        SessionLifecycle.resolve_session_options(issue, [account_config: %{accounts: %{"codex" => ["default", "work"]}, account_selection: "headroom"}], nil)

      assert Keyword.fetch!(opts, :account_name) == "work"
      assert Keyword.fetch!(opts, :account_selection_reason) == "headroom: codex/work=80%"
      assert Keyword.fetch!(opts, :env) == [{"CODEX_HOME", Path.join([home, ".aiur/accounts/codex/work"])}]
    end

    # #3970: a daemon started from a shell with CLAUDE_CONFIG_DIR/CODEX_HOME set
    # must not leak that profile into a worker that headroom put on `default`.
    test "the default account unsets the inherited profile variable" do
      for {backend, var} <- [{"claude", "CLAUDE_CONFIG_DIR"}, {"codex", "CODEX_HOME"}] do
        issue = %Issue{
          id: "default-#{backend}",
          identifier: "HR-D",
          selected_backend: backend,
          selected_account: "default",
          dispatch_selection: %{backend: backend, account: "default", route: backend, pinned: false, summary: "headroom: #{backend}/default=90%"}
        }

        {^backend, false, opts} =
          SessionLifecycle.resolve_session_options(issue, [account_config: %{accounts: %{backend => ["default"]}, account_selection: "headroom"}], nil)

        assert Keyword.fetch!(opts, :account_name) == "default"
        assert Keyword.fetch!(opts, :env) == [{var, false}]
      end
    end

    test "a pinned claim whose accounts are all exhausted still gets an account from the session's own selection" do
      :ok = Accounts.register("claude", "max", nil)
      issue = %Issue{id: "pinned", identifier: "HR-2", selected_backend: "claude", dispatch_selection: %{backend: "claude", account: nil, pinned: true, summary: "x"}}

      {"claude", false, opts} =
        SessionLifecycle.resolve_session_options(
          issue,
          [
            account_config: %{accounts: %{"claude" => ["max"]}, account_selection: "headroom"},
            account_usage_fetcher: fn _name -> %{"seven_day" => 10, "five_hour" => 20} end
          ],
          nil
        )

      assert Keyword.fetch!(opts, :account_name) == "max"
      refute Keyword.has_key?(opts, :account_selection_error)
    end
  end
end
