defmodule Aiur.CiLifecycleTestSupport do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Aiur.TestSupport, only: [write_workflow_file!: 2]

  alias Aiur.{Issue, TrackerIdentity, Workflow}
  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.{CiLifecycle, State}

  defmodule RecordingGitHubClient do
    alias Aiur.GitHub.IssueState

    @recipient_key {__MODULE__, :recipient}
    @update_result_key {__MODULE__, :update_result}
    @issues_key {__MODULE__, :issues}
    @request_key {__MODULE__, :request}

    def request_with(fun), do: Process.put(@request_key, fun)

    def record_to(pid), do: Process.put(@recipient_key, pid)
    def return(result), do: Process.put(@update_result_key, result)
    def return_issues(issues), do: Process.put(@issues_key, issues)

    def fetch_issue_states_by_ids(issue_ids) do
      issues = Process.get(@issues_key, [])
      {:ok, Enum.filter(issues, &(&1.id in issue_ids))}
    end

    def hydrate_blocked_by(issue), do: {:ok, issue}

    def update_issue_state(issue_id, state_name) do
      record_update(issue_id, state_name, [])
    end

    def update_issue_state(issue_id, state_name, opts) when is_list(opts) do
      record_update(issue_id, state_name, opts)
    end

    def remove_label(issue_id, label) when is_binary(issue_id) and is_binary(label) do
      case recipient() do
        recipient when is_pid(recipient) ->
          send(recipient, {:label_removed, issue_id, label})

          case Process.get(@request_key) do
            nil -> Process.get(@update_result_key, :ok)
            request_fun -> IssueState.remove_label(issue_id, label, request_fun: request_fun)
          end

        _other ->
          {:error, :unscoped_test_call}
      end
    end

    defp record_update(issue_id, state_name, opts) do
      case recipient() do
        recipient when is_pid(recipient) ->
          send(recipient, {:tracker_update, issue_id, state_name, opts})

          case Process.get(@request_key) do
            nil -> Process.get(@update_result_key, :ok)
            request_fun -> IssueState.update_issue_state(issue_id, state_name, Keyword.put(opts, :request_fun, request_fun))
          end

        _other ->
          {:error, :unscoped_test_call}
      end
    end

    defp recipient, do: Process.get(@recipient_key)
  end

  defmodule SlowTransitionClient do
    def update_issue_state(issue_id, next_state, opts) do
      recipient = Application.fetch_env!(:aiur, :ci_slow_transition_recipient)
      send(recipient, {:ci_transition_started, self(), issue_id, next_state, opts})

      receive do
        :finish_ci_transition -> :ok
      end
    end
  end

  def ci_lifecycle_setup(_context) do
    previous_client = Application.get_env(:aiur, :github_client_module)
    previous_store_path = Application.get_env(:aiur, :ci_approval_store_path)

    store_path = Aiur.TestSupport.tmp_root!("aiur_ci_lifecycle") <> ".json"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent",
      tracker_active_states: ["todo", "in-progress", "rework", "merging"],
      tracker_terminal_states: ["done", "cancelled", "canceled"]
    )

    Application.put_env(:aiur, :github_client_module, RecordingGitHubClient)
    Application.put_env(:aiur, :ci_approval_store_path, store_path)

    on_exit(fn ->
      restore_application_env(:github_client_module, previous_client)
      restore_application_env(:ci_approval_store_path, previous_store_path)
      File.rm(store_path)
    end)

    :ok
  end

  def poll_ci(state, issue, result, opts \\ []) do
    next =
      CiLifecycle.poll_github_ci(
        state,
        Keyword.merge(
          [
            # Hermetic: parked-ready restart dedupe seeds from the durable
            # alert ledger; tests never read the real ledger.
            parked_ready_alert_loader: fn -> MapSet.new() end,
            draft_stall_alert_loader: fn -> MapSet.new() end,
            ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
            ci_poller: fn [target], _opts ->
              assert target == issue.identifier
              {:ok, %{results: [Map.put(result, :target, target)], errors: []}}
            end
          ],
          opts
        )
      )

    maybe_route_ci_terminal(next, issue, result)
  end

  defp maybe_route_ci_terminal(state, issue, %{decision: outcome}) when outcome in [:passed, :failed] do
    handoff_state = if outcome == :passed, do: "in-progress", else: "rework"

    case get_in(state.running, [issue.id, :issue, Access.key(:state)]) do
      ^handoff_state ->
        current_issue = %{issue | state: handoff_state}
        RecordingGitHubClient.return_issues([current_issue])

        CiLifecycle.maybe_resume_for_ci_terminal(state, issue.identifier, outcome)

      _ ->
        state
    end
  end

  defp maybe_route_ci_terminal(state, _issue, _result), do: state

  def capture_alert_emitter(test_pid, ref) do
    fn topic, opts ->
      send(test_pid, {:parked_alert, ref, topic, opts})
      :ok
    end
  end

  def with_approved_head(%State{} = state, identifier, head_sha) do
    %{state | ci_lifecycle: %{state.ci_lifecycle | approved_heads: %{identifier => head_sha}}}
  end

  def running_state(issue, pid, status, attrs) do
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
          safe_checkpoints: [:notification],
          application_confirmation: :confirmed,
          generation: 101,
          version: 0
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

  def issue(identifier, state) do
    %Issue{
      id: identifier,
      identifier: identifier,
      state: state,
      title: "Characterize CI lifecycle",
      tracker_identity: %TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: "its-everdred",
        repository: "aiur",
        provider_id: "I_kwDO#{identifier}",
        identifier: "101",
        reason: nil
      }
    }
  end

  def unique_identifier(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  def start_recorder(topic \\ nil) do
    test_pid = self()

    recorder =
      spawn(fn ->
        if is_binary(topic), do: Exchange.subscribe(topic)
        send(test_pid, {:recorder_ready, self()})
        record_messages(test_pid, 1)
      end)

    assert_receive {:recorder_ready, ^recorder}, 2_000
    RecordingGitHubClient.record_to(recorder)
    on_exit(fn -> if Process.alive?(recorder), do: Process.exit(recorder, :kill) end)
    recorder
  end

  defp record_messages(test_pid, position) do
    receive do
      {:sync_recorder, reply_to, ref} ->
        send(reply_to, {:recorder_synced, ref})
        record_messages(test_pid, position)

      message ->
        send(test_pid, {:recorded, position, message})
        record_messages(test_pid, position + 1)
    end
  end

  def sync_recorder(recorder) do
    ref = make_ref()
    send(recorder, {:sync_recorder, self(), ref})
    assert_receive {:recorder_synced, ^ref}, 2_000
  end

  def restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  def restore_application_env(key, value), do: Application.put_env(:aiur, key, value)
end
