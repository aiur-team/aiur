# credo:disable-for-this-file Credo.Check.Warning.IoInspect
# Drive the orchestrator through the pause / resume / chat-send sequences
# that have surfaced UX bugs. Runnable directly:
#
#     mix run test/manual/pause_resume_scenarios.exs
#
# Not part of `mix test` — this is the end-to-end driver. It boots a minimal
# set of supervised children (TaskSupervisor, PubSub, WorkflowStore) plus an
# isolated orchestrator wired to the in-memory tracker, then exercises the
# orchestrator the same way the agent-list pane and conversation pane do.
#
# Asserts are inline; failures halt the script with `System.halt(1)`.

require Logger
Logger.configure(level: :warning)

alias Aiur.{Issue, Orchestrator, Workflow, WorkflowStore}

defmodule Manual.PauseResume do
  @moduledoc false

  def init_failures, do: Process.put(:manual_failures, 0)
  def bump_failures, do: Process.put(:manual_failures, Process.get(:manual_failures, 0) + 1)
  def failures, do: Process.get(:manual_failures, 0)

  def banner(msg) do
    IO.puts(IO.ANSI.bright() <> "\n=== " <> msg <> " ===" <> IO.ANSI.reset())
  end

  def assert_eq(actual, expected, label) do
    if actual == expected do
      IO.puts("  " <> IO.ANSI.green() <> "PASS" <> IO.ANSI.reset() <> " #{label}")
    else
      IO.puts(
        "  " <>
          IO.ANSI.red() <>
          "FAIL" <>
          IO.ANSI.reset() <> " #{label}\n    expected: #{inspect(expected)}\n    actual:   #{inspect(actual)}"
      )

      bump_failures()
    end
  end

  def assert_match(actual, label, fun) when is_function(fun, 1) do
    if fun.(actual) do
      IO.puts("  " <> IO.ANSI.green() <> "PASS" <> IO.ANSI.reset() <> " #{label}")
    else
      IO.puts(
        "  " <>
          IO.ANSI.red() <>
          "FAIL" <> IO.ANSI.reset() <> " #{label}\n    got: #{inspect(actual)}"
      )

      bump_failures()
    end
  end

  def spawn_worker_pid do
    spawn(fn ->
      receive do
        :stop -> :ok
      after
        60_000 -> :ok
      end
    end)
  end

  def running_entry(issue, status, pid) do
    %{
      pid: pid,
      ref: Process.monitor(pid),
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: status},
      session_id: "thread-#{issue.identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end
end

alias Manual.PauseResume, as: PR
PR.init_failures()

# --- bootstrap minimal supervision tree ---------------------------------------

{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

bootstrap_children = [
  {Phoenix.PubSub, name: Aiur.PubSub},
  {Registry, keys: :unique, name: Aiur.IssueLog.Registry},
  {DynamicSupervisor, strategy: :one_for_one, name: Aiur.IssueLog.Supervisor},
  {Task.Supervisor, name: Aiur.TaskSupervisor}
]

{:ok, _} = Supervisor.start_link(bootstrap_children, strategy: :one_for_one, name: Manual.Supervisor)

workflow_root = Aiur.TestSupport.tmp_root!("aiur_manual")
File.mkdir_p!(workflow_root)
workflow_file = Path.join(workflow_root, "config.yaml")

File.write!(workflow_file, """
tracker:
  kind: memory
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Cancelled
github:
  repo: example/test
  label_prefix: agent
polling:
  interval_seconds: 60
workspace:
  root: #{workflow_root}/workspaces
agent:
  kind: codex
  max_concurrent_agents: 1
codex:
  command: /bin/true
""")

Workflow.set_workflow_file_path(workflow_file)
{:ok, _} = WorkflowStore.start_link(name: Aiur.WorkflowStore)
WorkflowStore.force_reload()

issue_active = %Issue{
  id: "issue-active",
  identifier: "MT-ACTIVE",
  title: "Active ticket",
  state: "In Progress",
  labels: ["agent:in-progress"]
}

issue_queued_a = %Issue{
  id: "issue-queued-a",
  identifier: "MT-QA",
  title: "Queued A",
  state: "Todo",
  labels: ["agent:todo"]
}

issue_queued_b = %Issue{
  id: "issue-queued-b",
  identifier: "MT-QB",
  title: "Queued B",
  state: "Todo",
  labels: ["agent:todo"]
}

Application.put_env(:aiur, :memory_tracker_issues, [issue_active, issue_queued_a, issue_queued_b])

orchestrator_name = Module.concat(__MODULE__, :PauseResumeScenariosOrchestrator)
{:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

worker_pid = PR.spawn_worker_pid()

:sys.replace_state(pid, fn state ->
  %{
    state
    | session_max_concurrent_agents: 1,
      running: %{"issue-active" => PR.running_entry(issue_active, :working, worker_pid)},
      last_polled_issues: %{
        "issue-active" => issue_active,
        "issue-queued-a" => issue_queued_a,
        "issue-queued-b" => issue_queued_b
      }
  }
end)

# ============================================================================
# Scenario 1a — chat-send to a paused agent with NO free slot must error
# ============================================================================
PR.banner("Scenario 1a: chat-send-to-paused at cap returns a clear error")

status0 = Orchestrator.max_concurrent_agents(orchestrator_name)

PR.assert_match(status0, "starting status is 1/1 active", fn s ->
  s.active == 1 and s.paused == 0 and s.max == 1
end)

{:ok, _} = Orchestrator.pause_agent(orchestrator_name, "MT-ACTIVE")
send(pid, {:worker_control_state, "issue-active", :paused})
Process.sleep(50)

status1 = Orchestrator.max_concurrent_agents(orchestrator_name)

PR.assert_match(status1, "after pause: 0/1 active, 1 paused", fn s ->
  s.active == 0 and s.paused == 1 and s.max == 1
end)

{:ok, :started} = Orchestrator.resume_agent(orchestrator_name, "MT-QA")
Process.sleep(50)

status2 = Orchestrator.max_concurrent_agents(orchestrator_name)

PR.assert_match(status2, "after manual start of MT-QA: 1/1 active, 1 paused", fn s ->
  s.active == 1 and s.paused == 1 and s.max == 1
end)

send_result =
  Orchestrator.send_operator_message(orchestrator_name, "MT-ACTIVE", %{kind: :text, body: "hi"})

IO.inspect(send_result, label: "  send_operator_message result")
Process.sleep(50)

status3 = Orchestrator.max_concurrent_agents(orchestrator_name)
IO.inspect(status3, label: "  status after chat send to paused at cap")

PR.assert_match(status3, "chat send to paused at cap does NOT exceed max", fn s ->
  s.active <= s.max
end)

PR.assert_match(send_result, "chat send to paused at cap returns max_concurrent_agents_reached", fn
  {:error, :max_concurrent_agents_reached} -> true
  _ -> false
end)

# ============================================================================
# Scenario 1b — chat-send to a paused agent with a FREE slot auto-resumes
# Bump the cap to 2 so MT-ACTIVE has a free slot; chat-send should now flip
# its control status from :paused to :working and enqueue the message.
# ============================================================================
PR.banner("Scenario 1b: chat-send-to-paused with free slot auto-resumes")

{:ok, _} = Orchestrator.adjust_max_concurrent_agents(orchestrator_name, 1)

send_result_b =
  Orchestrator.send_operator_message(orchestrator_name, "MT-ACTIVE", %{kind: :text, body: "hi"})

IO.inspect(send_result_b, label: "  send_operator_message result")
Process.sleep(50)

PR.assert_match(send_result_b, "chat send to paused with capacity succeeds", fn
  {:ok, _request_id} -> true
  _ -> false
end)

status_b = Orchestrator.max_concurrent_agents(orchestrator_name)
IO.inspect(status_b, label: "  status after auto-resume")

PR.assert_match(status_b, "auto-resume: 2/2 active, 0 paused", fn s ->
  s.active == 2 and s.paused == 0 and s.max == 2
end)

# ============================================================================
# Scenario 2 — bumping max from 1→2 unblocks manual start of a queued ticket
# Real user flow: 1 active agent at max=1, bump to 2, manually start a queued
# ticket. Before the bump it must refuse; after the bump it must start.
# ============================================================================
PR.banner("Scenario 2: max bump unblocks manual start of queued ticket")

worker2 = PR.spawn_worker_pid()

:sys.replace_state(pid, fn state ->
  %{
    state
    | session_max_concurrent_agents: 1,
      running: %{"issue-active" => PR.running_entry(issue_active, :working, worker2)},
      claimed: MapSet.new(["issue-active"]),
      last_polled_issues: %{
        "issue-active" => issue_active,
        "issue-queued-a" => issue_queued_a,
        "issue-queued-b" => issue_queued_b
      }
  }
end)

status_a = Orchestrator.max_concurrent_agents(orchestrator_name)

PR.assert_match(status_a, "baseline: 1/1 active, 0 paused", fn s ->
  s.active == 1 and s.paused == 0 and s.max == 1
end)

attempt_before_bump = Orchestrator.resume_agent(orchestrator_name, "MT-QA")
IO.inspect(attempt_before_bump, label: "  manual start before bump")

PR.assert_match(attempt_before_bump, "manual start blocked while at max", fn
  {:error, :max_concurrent_agents_reached} -> true
  _ -> false
end)

{:ok, bumped_status} = Orchestrator.adjust_max_concurrent_agents(orchestrator_name, 1)
IO.inspect(bumped_status, label: "  status after bump")
PR.assert_eq(bumped_status.max, 2, "max bumped to 2")

attempt_after_bump = Orchestrator.resume_agent(orchestrator_name, "MT-QA")
IO.inspect(attempt_after_bump, label: "  manual start after bump")

PR.assert_match(attempt_after_bump, "manual start succeeds after max bump", fn
  {:ok, :started} -> true
  _ -> false
end)

# ============================================================================
# Scenario 3 — bumping the session max past the workflow value must clear the
# per-state cap so a 3rd manual start succeeds (regression for the “2/5 but
# turning on a 3rd just flashes red” issue).
# ============================================================================
PR.banner("Scenario 3: per-state cap honors the session-bumped max")

worker_a = PR.spawn_worker_pid()
worker_b = PR.spawn_worker_pid()

queued_issue_c = %Issue{
  id: "issue-queued-c",
  identifier: "MT-QC",
  title: "Queued C",
  state: "Todo",
  labels: ["agent:todo"]
}

issue_a_in_progress = %Issue{issue_active | id: "issue-a", identifier: "MT-A"}
issue_b_in_progress = %Issue{issue_active | id: "issue-b", identifier: "MT-B"}

Application.put_env(:aiur, :memory_tracker_issues, [
  issue_a_in_progress,
  issue_b_in_progress,
  queued_issue_c
])

:sys.replace_state(pid, fn state ->
  %{
    state
    | session_max_concurrent_agents: 5,
      running: %{
        "issue-a" => PR.running_entry(issue_a_in_progress, :working, worker_a),
        "issue-b" => PR.running_entry(issue_b_in_progress, :working, worker_b)
      },
      claimed: MapSet.new(["issue-a", "issue-b"]),
      last_polled_issues: %{
        "issue-a" => issue_a_in_progress,
        "issue-b" => issue_b_in_progress,
        "issue-queued-c" => queued_issue_c
      }
  }
end)

status_c = Orchestrator.max_concurrent_agents(orchestrator_name)
IO.inspect(status_c, label: "  baseline status (workflow max=1, session=5)")

PR.assert_match(status_c, "session max overrides workflow max", fn s ->
  s.active == 2 and s.max == 5
end)

start_c = Orchestrator.resume_agent(orchestrator_name, "MT-QC")
IO.inspect(start_c, label: "  manual start of 3rd agent")

PR.assert_match(start_c, "3rd manual start succeeds after bumping past workflow max", fn
  {:ok, :started} -> true
  _ -> false
end)

Process.exit(pid, :normal)

case PR.failures() do
  0 ->
    PR.banner("All scenarios passed")

  n ->
    IO.puts(IO.ANSI.red() <> "\n#{n} scenario assertion(s) failed" <> IO.ANSI.reset())
    System.halt(1)
end
