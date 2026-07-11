defmodule Aiur.OrchestratorCILifecycleTest do
  use Aiur.TestSupport

  alias Aiur.CIApprovalStore
  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.{CiLifecycle, State}

  defmodule RecordingGitHubClient do
    def update_issue_state(issue_id, state_name) do
      if is_pid(recipient()) do
        send(recipient(), {:tracker_update, issue_id, state_name})
      end

      Application.get_env(:aiur, :ci_lifecycle_update_result, :ok)
    end

    defp recipient, do: Application.get_env(:aiur, :ci_lifecycle_recipient)
  end

  setup do
    previous_client = Application.get_env(:aiur, :github_client_module)
    previous_recipient = Application.get_env(:aiur, :ci_lifecycle_recipient)
    previous_result = Application.get_env(:aiur, :ci_lifecycle_update_result)
    previous_store_path = Application.get_env(:aiur, :ci_approval_store_path)

    store_path =
      Path.join(
        System.tmp_dir!(),
        "aiur_ci_lifecycle_#{System.unique_integer([:positive])}.json"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent",
      tracker_active_states: ["todo", "in-progress", "rework", "merging"],
      tracker_terminal_states: ["done", "cancelled", "canceled"]
    )

    Application.put_env(:aiur, :github_client_module, RecordingGitHubClient)
    Application.put_env(:aiur, :ci_lifecycle_update_result, :ok)
    Application.put_env(:aiur, :ci_approval_store_path, store_path)

    on_exit(fn ->
      restore_application_env(:github_client_module, previous_client)
      restore_application_env(:ci_lifecycle_recipient, previous_recipient)
      restore_application_env(:ci_lifecycle_update_result, previous_result)
      restore_application_env(:ci_approval_store_path, previous_store_path)
      File.rm(store_path)
    end)

    :ok
  end

  describe "CI lifecycle coordination" do
    test "pending CI writes ci-wait before pausing a live human-review runner" do
      identifier = unique_identifier("ci-pending")
      recorder = start_recorder()
      Application.put_env(:aiur, :ci_lifecycle_recipient, recorder)

      issue = issue(identifier, "human-review")
      started_at = DateTime.add(DateTime.utc_now(), -30, :second)
      state = running_state(issue, recorder, :working, started_at: started_at)

      next = poll_ci(state, issue, %{decision: :pending, head_sha: "pending-head"})

      assert_receive {:recorded, 1, {:tracker_update, ^identifier, "ci-wait"}}, 500
      assert_receive {:recorded, 2, {:pause_agent, request_id}}, 500
      assert is_integer(request_id)

      entry = Map.fetch!(next.running, identifier)

      assert entry.issue.state == "ci-wait"
      assert entry.control.status == :paused
      assert entry.control.can_interrupt
      assert entry.paused_reason == :ci_wait
      assert %DateTime{} = entry.paused_at
      assert entry.started_at == started_at
      assert MapSet.member?(next.claimed, identifier)
      assert Process.alive?(recorder)
    end

    test "a failed tracker transition publishes nothing and leaves the runner untouched" do
      identifier = unique_identifier("ci-transition-failure")
      topic = "ticket.#{identifier}.ci.failed"
      recorder = start_recorder(topic)
      Application.put_env(:aiur, :ci_lifecycle_recipient, recorder)
      Application.put_env(:aiur, :ci_lifecycle_update_result, {:error, :tracker_down})

      issue = issue(identifier, "ci-wait")
      state = running_state(issue, recorder, :paused, paused_reason: :ci_wait)

      next =
        poll_ci(state, issue, %{
          decision: :failed,
          head_sha: "failed-head",
          pr_number: 941,
          failures: [%{name: "lint", result: "failure", excerpt: "failed"}]
        })

      assert_receive {:recorded, 1, {:tracker_update, ^identifier, "rework"}}, 500
      refute_receive {:recorded, 2, _message}, 100

      assert next.running == state.running
      assert next.ci_lifecycle == state.ci_lifecycle
      assert MapSet.member?(next.claimed, identifier)
    end

    test "passing CI records the head and publishes after the human-review write" do
      identifier = unique_identifier("ci-passed")
      topic = "ticket.#{identifier}.ci.passed"
      recorder = start_recorder(topic)
      Application.put_env(:aiur, :ci_lifecycle_recipient, recorder)

      issue = issue(identifier, "ci-wait")
      state = running_state(issue, recorder, :paused, paused_reason: :ci_wait)

      next =
        poll_ci(state, issue, %{
          decision: :passed,
          head_sha: "approved-head",
          pr_number: 941
        })

      assert_receive {:recorded, 1, {:tracker_update, ^identifier, "human-review"}}, 500

      assert_receive {:recorded, 2,
                      {:event,
                       %{
                         topic: ^topic,
                         source: :github,
                         head_sha: "approved-head",
                         pr_number: 941,
                         message: "CI passed for the current PR head"
                       }}},
                     500

      refute_receive {:recorded, 3, _message}, 100

      assert next.running[identifier].issue.state == "human-review"
      assert next.running[identifier].control.status == :paused
      assert next.ci_lifecycle.approved_heads == %{identifier => "approved-head"}
      assert CIApprovalStore.load().approved_heads == %{identifier => "approved-head"}
    end

    test "pending CI is idempotent for an existing ci-wait ticket" do
      identifier = unique_identifier("ci-idempotent")
      recorder = start_recorder()
      Application.put_env(:aiur, :ci_lifecycle_recipient, recorder)

      issue = issue(identifier, "ci-wait")
      state = running_state(issue, recorder, :paused, paused_reason: :ci_wait)

      next = poll_ci(state, issue, %{decision: :pending, head_sha: "same-head"})

      refute_receive {:recorded, _position, _message}, 100
      assert next == state
    end
  end

  defp poll_ci(state, issue, result) do
    CiLifecycle.poll_github_ci(state,
      ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
      ci_poller: fn [target], _opts ->
        assert target == issue.identifier
        {:ok, %{results: [Map.put(result, :target, target)], errors: []}}
      end
    )
  end

  defp running_state(issue, pid, status, attrs) do
    entry =
      %{
        pid: pid,
        ref: make_ref(),
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.utc_now(),
        control: %{
          status: status,
          can_interrupt: true,
          safe_checkpoints: [:notification]
        }
      }
      |> Map.merge(Map.new(attrs))

    %State{
      running: %{issue.id => entry},
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{},
      max_concurrent_agents: 6
    }
  end

  defp issue(identifier, state) do
    %Issue{
      id: identifier,
      identifier: identifier,
      state: state,
      title: "Characterize CI lifecycle"
    }
  end

  defp unique_identifier(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp start_recorder(topic \\ nil) do
    test_pid = self()

    recorder =
      spawn(fn ->
        if is_binary(topic), do: Exchange.subscribe(topic)
        send(test_pid, {:recorder_ready, self()})
        record_messages(test_pid, 1)
      end)

    assert_receive {:recorder_ready, ^recorder}, 500
    on_exit(fn -> if Process.alive?(recorder), do: Process.exit(recorder, :kill) end)
    recorder
  end

  defp record_messages(test_pid, position) do
    receive do
      message ->
        send(test_pid, {:recorded, position, message})
        record_messages(test_pid, position + 1)
    end
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)
end
