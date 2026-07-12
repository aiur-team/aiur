defmodule AiurWeb.PresenterTest do
  use Aiur.TestSupport

  alias Aiur.Events.SubscriptionStore
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias AiurWeb.Presenter

  defp running_entry(issue_id, identifier, status, issue_state \\ "In Progress") do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: issue_state, title: "Row #{identifier}"},
      worker_host: nil,
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: status},
      session_id: "thread-#{identifier}",
      codex_app_server_pid: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now(),
      last_codex_timestamp: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil
    }
  end

  test "projects explicit waiting reasons, staleness, CI/PR, and idle rows" do
    orchestrator_name = Module.concat(__MODULE__, :FleetOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    ci_wait_entry =
      "issue-ci-wait"
      |> running_entry("MT-700", :paused, "ci-wait")
      |> Map.merge(%{
        paused_reason: :ci_wait,
        last_ci_result: %{decision: :pending, pr_number: 55, head_sha: "abc123"}
      })

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"issue-ci-wait" => ci_wait_entry},
          retry_attempts: %{
            "mt-701" => %{attempt: 1, timer_ref: nil, due_at_ms: System.monotonic_time(:millisecond) + 5_000, identifier: "MT-701"}
          },
          last_polled_issues: %{
            "issue-ci-wait" => %Issue{id: "issue-ci-wait", identifier: "MT-700", state: "ci-wait"},
            "issue-idle" => %Issue{id: "issue-idle", identifier: "MT-702", state: "human-review", title: "Idle review"}
          }
      }
    end)

    payload = Presenter.state_payload(orchestrator_name, 1_000)

    assert payload.counts == %{running: 1, retrying: 1, idle: 1}

    assert [running_row] = payload.running
    assert running_row.issue_identifier == "MT-700"
    assert running_row.waiting_reason == :waiting_for_ci
    assert running_row.ci == %{decision: :pending, pr_number: 55, head_sha: "abc123"}
    assert running_row.review == :not_started
    assert running_row.open_decision_count == 0
    assert is_integer(running_row.stale_for_seconds)

    assert [retry_row] = payload.retrying
    assert retry_row.waiting_reason == :backing_off

    assert [idle_row] = payload.idle
    assert idle_row.issue_identifier == "MT-702"
    assert idle_row.waiting_reason == :waiting_for_review
    assert idle_row.review == :awaiting
  end

  test "open_decision_count reuses the existing SubscriptionStore open-attentions count" do
    orchestrator_name = Module.concat(__MODULE__, :DecisionCountOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    identifier = "MT-800"

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      SubscriptionStore.stop(identifier)
    end)

    :ok = SubscriptionStore.attach(identifier)
    :ok = SubscriptionStore.add_attention(identifier, "needs-review")

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-decision" => running_entry("issue-decision", identifier, :working)}}
    end)

    payload = Presenter.state_payload(orchestrator_name, 1_000)

    assert [running_row] = payload.running
    assert running_row.open_decision_count == 1
  end
end
