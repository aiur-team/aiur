Code.require_file(Path.expand("../control_cli/fixture.exs", __DIR__))

defmodule Aiur.OrchestratorStatusCliAgentsTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.DecisionStore
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Issue

  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
  end

  alias Aiur.Orchestrator.StatusCLI, as: AgentControlCLI

  describe "agents/0" do
    test "prints persisted runtime reason labels exactly", %{orchestrator: pid} do
      agent =
        "issue-ci"
        |> running_entry("repo#ci", :paused)
        |> Map.put(:issue, %Issue{id: "issue-ci", identifier: "repo#ci", state: "ci-wait", labels: ["agent:ci-wait", "agent:ci-red"]})

      :sys.replace_state(pid, fn state -> %{state | running: %{"issue-ci" => agent}} end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "repo#ci"
      assert output =~ "agent:ci-wait,agent:ci-red"
    end

    test "prints empty table when no agents are running" do
      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "ISSUE  STATE      RUNTIME  ACTIVITY"
      assert output =~ "(no active agents)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "prints one line per agent with state and current activity", %{orchestrator: pid} do
      active =
        "issue-44"
        |> running_entry("repo#44", :working)
        |> Map.merge(%{
          started_at: DateTime.add(DateTime.utc_now(), -90, :second),
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: "command_execution",
          last_codex_message: "running mix test"
        })

      paused =
        "issue-88"
        |> running_entry("repo#88", :paused)
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          last_codex_message: nil
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-44" => active, "issue-88" => paused}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#44"
      assert output =~ "working"
      # Activity prefers the latest event name; runtime renders compactly.
      assert output =~ "command_execution"
      assert output =~ "1m"
      # A paused agent shows its work-state instead of stale activity text.
      assert output =~ "#88"
      assert output =~ "(paused)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "hides ordinary idle tickets by default and shows them with --all" do
      idle = fn number ->
        %{identifier: "repo##{number}", issue_id: "#{number}", work_state: :idle, state: "todo", queue_depth: 0}
      end

      attention_idle = [
        idle.(503) |> Map.put(:work_state, :paused),
        idle.(504) |> Map.put(:waiting_reason, :waiting_for_human),
        idle.(505) |> Map.put(:queue_depth, 1),
        idle.(506) |> Map.put(:claim_released?, true),
        idle.(507) |> Map.put(:waiting_reason, :waiting_for_dependency)
      ]

      running = [
        running_entry("issue-1", "repo#1", :working) |> Map.put(:issue_id, "1"),
        running_entry("issue-2", "repo#2", :working) |> Map.put(:issue_id, "2")
      ]

      snapshot = %{running: running, retrying: [], idle: Enum.map(3..502, idle) ++ attention_idle}
      freshness = %{status: :current, age_ms: 0, observed_at: DateTime.to_iso8601(DateTime.utc_now())}
      view = {:ok, snapshot, freshness}

      default_output = capture_io(fn -> AgentControlCLI.agents(fleet_view: view) end)
      assert length(Regex.scan(~r/^#\d+\s/m, default_output)) == 7
      refute default_output =~ "#3"
      assert Enum.all?(503..507, &(default_output =~ "##{&1}"))
      assert default_output =~ "(500 idle tickets hidden; use --all to show)"

      all_output = capture_io(fn -> AgentControlCLI.agents(all: true, fleet_view: view) end)
      assert length(Regex.scan(~r/^#\d+\s/m, all_output)) == 507
      assert all_output =~ "#507"
      refute all_output =~ "idle tickets hidden"
    end

    test "shows startup and retry as distinct from a live turn", %{orchestrator: pid} do
      at = DateTime.utc_now()
      starting = running_entry("issue-2895", "repo#2895", :working) |> Map.put(:session_id, nil)

      retry = %{
        identifier: "repo#2896",
        attempt: 1,
        due_at_ms: System.monotonic_time(:millisecond) + 10_000,
        error: "startup failed: {:port_exit, 23}",
        last_failure_at: at
      }

      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{"issue-2895" => starting},
            retry_attempts: %{
              "issue-2896" => retry,
              "issue-2897" => %{retry | identifier: "repo#2897", error: "startup failed: private-key-value"}
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)
      assert output =~ ~r/#2895\s+agent:in-progress\s/
      assert output =~ "(starting provider; no live turn yet)"
      assert output =~ ~r/#2896\s+agent:retrying\s/
      assert output =~ "startup failed: {:port_exit, 23}"
      assert output =~ DateTime.to_iso8601(at)
      assert output =~ "#2897"
      refute output =~ "private-key-value"
    end

    test "status and agents agree on the human wait for a decision and a rework ticket (#2698)",
         %{orchestrator: pid} do
      # Khala #17 and #52 were both live, working and labelled `rework`. #52 had
      # an open decision; #17 had none. `status` said waiting_for_human for both
      # while `agents` said working for both.
      :ok = SubscriptionStore.attach("repo#52")
      :ok = SubscriptionStore.add_attention("repo#52", "github-credential-missing")
      assert {:ok, %{decision: decision}} = DecisionStore.request(%{"question" => "Provide the missing credential?", "blocking" => true}, ticket: %{identifier: "repo#52"})
      on_exit(fn -> DecisionStore.expire(decision.decision_id, "agent_not_running") end)
      on_exit(fn -> SubscriptionStore.stop("repo#52") end)

      working_rework = fn issue_id, identifier ->
        issue_id
        |> running_entry(identifier, :working)
        |> update_in([:issue], &%{&1 | state: "rework"})
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: "usage/update",
          last_codex_message: nil
        })
      end

      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{
              "issue-17" => working_rework.("issue-17", "repo#17"),
              "issue-52" => working_rework.("issue-52", "repo#52")
            }
        }
      end)

      status = capture_io(fn -> AgentControlCLI.status() end)
      agents = capture_io(fn -> AgentControlCLI.agents() end)

      status_line = fn number -> Enum.find(String.split(status, "\n"), &String.starts_with?(&1, "##{number} ")) end
      agents_line = fn number -> Enum.find(String.split(agents, "\n"), &String.starts_with?(&1, "##{number} ")) end

      # Open decision: both surfaces say the agent waits for a human.
      assert status_line.(52) =~ "waiting=waiting_for_human"
      assert status_line.(52) =~ "agent:paused-decision"
      assert agents_line.(52) =~ ~r/^#52\s+agent:paused-decision\s/
      assert agents_line.(52) =~ "(waiting_for_human: 1 open decision)"

      # No decision: neither surface says waiting_for_human; both say it works.
      assert status_line.(17) =~ "waiting=active"
      refute status =~ ~r/^#17 .*waiting_for_human/m
      assert agents_line.(17) =~ ~r/^#17\s+working\s/
      refute agents_line.(17) =~ "waiting"
    end

    test "preserves paused and deactivated states alongside open attentions", %{orchestrator: pid} do
      for identifier <- ["repo#46", "repo#47"] do
        :ok = SubscriptionStore.attach(identifier)
        :ok = SubscriptionStore.add_attention(identifier, "github-credential-missing")
        assert {:ok, %{decision: decision}} = DecisionStore.request(%{"question" => "Provide the missing credential?", "blocking" => true}, ticket: %{identifier: identifier})
        on_exit(fn -> DecisionStore.expire(decision.decision_id, "agent_not_running") end)
        on_exit(fn -> SubscriptionStore.stop(identifier) end)
      end

      paused =
        "issue-46"
        |> running_entry("repo#46", :paused)
        |> update_in([:issue], &%{&1 | paused: true})
        |> Map.put(:paused_reason, :label_override)

      deactivated = running_entry("issue-47", "repo#47", :deactivated)

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-46" => paused, "issue-47" => deactivated}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ ~r/^#46\s+agent:paused-decision\s+.*\(waiting_for_human: 1 open decision\)/m
      assert output =~ ~r/^#47\s+deactivated\s+.*\(waiting_for_human: 1 open decision\)/m
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "shows label override as the pause reason", %{orchestrator: pid} do
      paused =
        "issue-46"
        |> running_entry("repo#46", :paused)
        |> update_in([:issue], &%{&1 | paused: true})
        |> Map.merge(%{
          paused_reason: :label_override,
          codex_app_server_pid: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          last_codex_message: nil
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-46" => paused}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#46"
      assert output =~ "(paused: label override)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "falls back to last_codex_message, then to a placeholder, and collapses long activity", %{orchestrator: pid} do
      base = fn id, ident -> id |> running_entry(ident, :working) |> Map.merge(%{codex_app_server_pid: nil, last_codex_timestamp: nil}) end

      # event nil -> fall back to message; multi-line + >80 chars -> single line, truncated.
      long = "tool\noutput " <> String.duplicate("x", 120)

      msg_only = base.("issue-1", "repo#1") |> Map.merge(%{last_codex_event: nil, last_codex_message: long})
      idle = base.("issue-2", "repo#2") |> Map.merge(%{last_codex_event: nil, last_codex_message: nil})

      deactivated =
        "issue-3"
        |> running_entry("repo#3", :deactivated)
        |> Map.merge(%{codex_app_server_pid: nil, last_codex_timestamp: nil, last_codex_event: nil, last_codex_message: nil})

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-1" => msg_only, "issue-2" => idle, "issue-3" => deactivated}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      # Activity is collapsed to a single line and ellipsis-truncated.
      assert output =~ "tool output xxx"
      refute output =~ "tool\noutput"
      assert output =~ "…"
      # No-activity and deactivated placeholders render.
      assert output =~ "(no activity yet)"
      assert output =~ "(deactivated)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "formats structured codex activity maps without crashing", %{orchestrator: pid} do
      activity = %{
        event: :notification,
        message: %{
          "method" => "account/rateLimits/updated",
          "params" => %{
            "rateLimits" => %{
              "credits" => %{"hasCredits" => true, "unlimited" => false},
              "limitId" => "codex",
              "planType" => "business"
            }
          }
        },
        timestamp: DateTime.utc_now()
      }

      active =
        "issue-44"
        |> running_entry("repo#44", :working)
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: :notification,
          last_codex_message: activity
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-44" => active}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#44"
      assert output =~ "rate limits updated"
      refute output =~ ~r/#44\s+working\s+\S+\s+notification/
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "formats codex activity maps wrapped in payload fields", %{orchestrator: pid} do
      activity = %{
        event: :notification,
        message: %{
          payload: %{
            "method" => "item/started",
            "params" => %{"item" => %{"type" => "reasoning", "id" => "rs_1234567890abcdef"}}
          }
        },
        timestamp: DateTime.utc_now()
      }

      active =
        "issue-45"
        |> running_entry("repo#45", :working)
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: :notification,
          last_codex_message: activity
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-45" => active}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#45"
      assert output =~ "item started: reasoning"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "formats structured codex activity when the event itself is a map", %{orchestrator: pid} do
      activity = %{
        event: :notification,
        message: %{
          "method" => "item/started",
          "params" => %{"item" => %{"type" => "reasoning", "content" => [], "summary" => []}}
        },
        timestamp: DateTime.utc_now()
      }

      active =
        "issue-46"
        |> running_entry("repo#46", :working)
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: activity,
          last_codex_message: nil
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-46" => active}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#46"
      assert output =~ "item started: reasoning"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "inspects unexpected non-string activity without crashing", %{orchestrator: pid} do
      active =
        "issue-47"
        |> running_entry("repo#47", :working)
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: {:unexpected, %{payload: make_ref()}},
          last_codex_message: nil
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-47" => active}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#47"
      assert output =~ "{:unexpected,"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "reports a clear error when the orchestrator is unavailable", %{orchestrator: pid} do
      Process.unregister(Orchestrator)

      try do
        output = capture_io(fn -> AgentControlCLI.agents() end)

        assert output =~ "__AIUR_CONTROL_ERROR__:aiur: agents query failed because the orchestrator is not running"
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      after
        Process.register(pid, Orchestrator)
      end
    end

    test "distinguishes a bounded query timeout", %{orchestrator: pid} do
      :sys.suspend(pid)

      try do
        output = capture_io(fn -> AgentControlCLI.agents(snapshot_timeout_ms: 1) end)

        assert output =~ "__AIUR_CONTROL_ERROR__:aiur: agents query timed out after 1ms; outcome is unknown"
        assert output =~ "__AIUR_CONTROL_EXIT__:124"
      after
        :sys.resume(pid)
      end
    end
  end
end
