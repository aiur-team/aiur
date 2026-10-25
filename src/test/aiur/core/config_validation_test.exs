defmodule Aiur.Core.ConfigValidationTest do
  use Aiur.TestSupport
  import Aiur.TestSupport.RejectedWorkflow
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.LifecycleFence

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_seconds: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_seconds == 120
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.linear.assignee == nil
    assert config.max_vertical_panes == 3
    assert Config.max_vertical_panes() == 3
    assert config.agent.max_turns == 20
    assert config.agent.max_concurrent_builds == 4
    assert Config.max_concurrent_builds() == 4

    assert {:error, {:invalid_workflow_config, message}} = write_rejected_workflow_file!(Workflow.workflow_file_path(), poll_interval_seconds: "invalid")
    assert message =~ "polling.interval_seconds"
    # The rejected reload leaves the last known good config in effect (#3961).
    assert Config.settings!().polling.interval_seconds == 120

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_seconds: 45)
    assert Config.settings!().polling.interval_seconds == 45

    write_workflow_file!(Workflow.workflow_file_path(), max_vertical_panes: 4)
    assert Config.settings!().max_vertical_panes == 4
    assert Config.max_vertical_panes() == 4

    assert {:error, {:invalid_workflow_config, message}} = write_rejected_workflow_file!(Workflow.workflow_file_path(), max_vertical_panes: 0)
    assert message =~ "max_vertical_panes"

    assert {:error, {:invalid_workflow_config, message}} = write_rejected_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert message =~ "agent.max_turns"

    assert {:error, {:invalid_workflow_config, message}} = write_rejected_workflow_file!(Workflow.workflow_file_path(), max_concurrent_builds: -1)
    assert message =~ "agent.max_concurrent_builds"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_builds: 0)
    assert Config.max_concurrent_builds() == 0

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    # `none` means uncapped — the autonomous loop is never bounded by turns.
    write_workflow_file!(Workflow.workflow_file_path(), max_turns: "none")
    assert Config.settings!().agent.max_turns == nil

    assert {:error, {:invalid_workflow_config, message}} = write_rejected_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    assert {:error, {:invalid_workflow_config, message}} =
             write_rejected_workflow_file!(Workflow.workflow_file_path(),
               tracker_project_slug: "project",
               codex_command: ""
             )

    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().agent.codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: [System.tmp_dir!()]}
    )

    assert :ok = Config.validate!()

    assert {:error, {:invalid_workflow_config, message}} = write_rejected_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert message =~ "codex.approval_policy"

    assert {:error, {:invalid_workflow_config, message}} = write_rejected_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "current operator .aiur/config file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()

    try do
      Workflow.set_workflow_file_path(Path.expand("../.aiur/config", File.cwd!()))

      assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
      assert is_map(config)

      tracker = Map.get(config, "tracker", %{})
      assert is_map(tracker)
      assert Map.get(tracker, "kind") in ["linear", "github", "memory"]
      assert is_list(Map.get(tracker, "active_states"))
      assert is_list(Map.get(tracker, "terminal_states"))

      hooks = Map.get(config, "hooks", %{})
      assert is_map(hooks)
      assert is_binary(Map.get(hooks, "after_create"))
      assert is_binary(Map.get(hooks, "before_remove"))
      assert String.trim(Map.get(hooks, "after_create")) != ""
      assert String.trim(Map.get(hooks, "before_remove")) != ""

      assert String.trim(prompt) != ""
      assert prompt =~ "{{ issue.identifier }}"
      assert prompt =~ "{{ issue.title }}"
      assert is_binary(Config.workflow_prompt())
      assert Config.workflow_prompt() == prompt
    after
      Workflow.set_workflow_file_path(original_workflow_path)
    end
  end

  test "production config treats GitHub closed as terminal so a fenced closed issue is finalized" do
    original_workflow_path = Workflow.workflow_file_path()

    try do
      Workflow.set_workflow_file_path(Path.expand("../.aiur/config", File.cwd!()))

      assert {:ok, %{config: config}} = Workflow.load()

      terminal_states =
        config
        |> Map.get("tracker", %{})
        |> Map.get("terminal_states", [])
        |> Enum.map(&DispatchPolicy.normalize_issue_state/1)
        |> Enum.reject(&(&1 == ""))
        |> MapSet.new()

      # Config-drift guard for #1329: the repo's own production config must treat
      # GitHub `closed` as a terminal state, or a closed-but-fenced running entry
      # is never released and `aiur status` keeps showing the ticket as running.
      assert MapSet.member?(terminal_states, "closed")
      assert DispatchPolicy.terminal_issue_state?("closed", terminal_states)

      issue_id = "issue-prod-config-closed"
      observed = %Issue{id: issue_id, identifier: "PROD-1", state: "closed"}

      fenced_entry = fn opened_at ->
        %{
          identifier: "PROD-1",
          issue: observed,
          control: %{status: :working},
          lifecycle_fence: %{
            authoritative_state: "in-progress",
            generation: 1,
            opened_at: opened_at,
            pending_item_ids: MapSet.new([1])
          }
        }
      end

      fresh_state = %Orchestrator.State{running: %{issue_id => fenced_entry.(DateTime.utc_now())}}

      assert {:fenced, _next} =
               LifecycleFence.reconcile_observed_state(fresh_state, observed, terminal_states)

      expired_state = %Orchestrator.State{
        running: %{issue_id => fenced_entry.(DateTime.add(DateTime.utc_now(), -31, :second))}
      }

      assert :admit =
               LifecycleFence.reconcile_observed_state(expired_state, observed, terminal_states)
    after
      Workflow.set_workflow_file_path(original_workflow_path)
    end
  end

  test "terminal fence grace is configurable and bounds teardown of a closed observation" do
    original_workflow_path = Workflow.workflow_file_path()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_terminal_states: ["done", "closed"],
        tracker_terminal_fence_grace_seconds: 60
      )

      assert Config.terminal_fence_grace_seconds() == 60

      terminal_states = DispatchPolicy.terminal_state_set()
      assert MapSet.member?(terminal_states, "closed")

      issue_id = "issue-grace-configurable"
      observed = %Issue{id: issue_id, identifier: "GRACE-1", state: "closed"}

      fenced_entry = fn opened_at ->
        %{
          identifier: "GRACE-1",
          issue: observed,
          control: %{status: :working},
          lifecycle_fence: %{
            authoritative_state: "in-progress",
            generation: 1,
            opened_at: opened_at,
            pending_item_ids: MapSet.new([1])
          }
        }
      end

      # 45s old but the grace is 60s: still fenced, runner retained.
      within_grace = %Orchestrator.State{
        running: %{issue_id => fenced_entry.(DateTime.add(DateTime.utc_now(), -45, :second))}
      }

      assert {:fenced, _next} =
               LifecycleFence.reconcile_observed_state(within_grace, observed, terminal_states)

      # 61s old, past the configured 60s grace: admitted for teardown.
      past_grace = %Orchestrator.State{
        running: %{issue_id => fenced_entry.(DateTime.add(DateTime.utc_now(), -61, :second))}
      }

      assert :admit = LifecycleFence.reconcile_observed_state(past_grace, observed, terminal_states)
    after
      Workflow.set_workflow_file_path(original_workflow_path)
    end
  end
end
