defmodule Aiur.OrchestratorDeactivateSupport do
  @moduledoc false
  import ExUnit.Assertions
  import Aiur.TestSupport

  alias Aiur.Events.BranchRefStore
  alias Aiur.GitHub.CodeOwners
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.PauseResume
  alias Aiur.TrackerIdentity
  alias Aiur.Workflow

  defmodule ErrorLinearClient do
    @moduledoc false
    def fetch_issue_states_by_ids(_issue_ids), do: {:error, :tracker_down}

    def graphql(query, %{"issueId" => _issue_id, "stateName" => "rework"})
        when is_binary(query) do
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{"states" => %{"nodes" => [%{"id" => "state-rework"}]}}
           }
         }
       }}
    end

    def graphql(query, %{issueId: _issue_id, stateName: "rework"})
        when is_binary(query) do
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{"states" => %{"nodes" => [%{"id" => "state-rework"}]}}
           }
         }
       }}
    end

    def graphql(query, %{"issueId" => _issue_id, "stateId" => "state-rework"})
        when is_binary(query) do
      {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
    end

    def graphql(query, %{issueId: _issue_id, stateId: "state-rework"})
        when is_binary(query) do
      {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
    end
  end

  defmodule FlakyReworkGitHubClient do
    @moduledoc false
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}
    def fetch_candidate_issues, do: {:ok, []}
    def hydrate_blocked_by(issue), do: {:ok, issue}

    def update_issue_state(issue_id, state_name) do
      if self() == Application.get_env(:aiur, :flaky_rework_owner) do
        recipient = Application.get_env(:aiur, :flaky_rework_recipient)
        pid = Application.fetch_env!(:aiur, :flaky_rework_agent)

        if is_pid(recipient) do
          send(recipient, {:flaky_rework_update, issue_id, state_name})
        end

        Agent.get_and_update(pid, fn
          [result | rest] -> {result, rest}
          [] -> {:ok, []}
        end)
      else
        {:error, :unexpected_test_caller}
      end
    end
  end

  defmodule PauseOverrideGitHubClient do
    @moduledoc false
    def hydrate_blocked_by(issue), do: {:ok, issue}

    def remove_label(issue_id, label) do
      recipient = Application.get_env(:aiur, :pause_override_recipient)

      if is_pid(recipient), do: send(recipient, {:pause_override_remove_label, issue_id, label})

      Application.get_env(:aiur, :pause_override_remove_result, :ok)
    end
  end

  defmodule HumanReviewGuardGitHubClient do
    @moduledoc false
    def hydrate_blocked_by(issue), do: {:ok, issue}

    def verify_human_review_ready(issue_id) do
      if is_pid(recipient()), do: send(recipient(), {:human_review_verify, issue_id})
      Application.get_env(:aiur, :human_review_ready_result, :ok)
    end

    def update_issue_state(issue_id, state_name) do
      if is_pid(recipient()), do: send(recipient(), {:human_review_update, issue_id, state_name})
      :ok
    end

    def update_issue_state(issue_id, state_name, opts) do
      "human-review" = Keyword.fetch!(opts, :expected_state)
      update_issue_state(issue_id, state_name)
    end

    defp recipient, do: Application.get_env(:aiur, :human_review_guard_recipient)
  end

  defmodule DirectDispatchGitHubClient do
    @moduledoc false
    def hydrate_blocked_by(issue), do: {:ok, issue}

    def update_issue_state(issue_id, state_name) do
      if is_pid(recipient()),
        do: send(recipient(), {:direct_dispatch_update, issue_id, state_name})

      :ok
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(recipient(), {:direct_dispatch_fetch, issue_ids})

      issues =
        :aiur
        |> Application.fetch_env!(:direct_dispatch_issues)
        |> Enum.filter(&(&1.id in issue_ids))

      {:ok, issues}
    end

    def fetch_candidate_issues do
      send(recipient(), :direct_dispatch_candidate_fetch)
      {:ok, []}
    end

    defp recipient, do: Application.get_env(:aiur, :direct_dispatch_recipient)
  end

  defmodule CIWatcherGitHubClient do
    @moduledoc false
    def hydrate_blocked_by(issue), do: {:ok, issue}

    def update_issue_state(issue_id, state_name) do
      if is_pid(recipient()), do: send(recipient(), {:ci_watcher_update, issue_id, state_name})
      :ok
    end

    def update_issue_state(issue_id, state_name, opts) do
      if is_pid(recipient()), do: send(recipient(), {:ci_watcher_update_opts, issue_id, state_name, opts})
      if is_pid(recipient()), do: send(recipient(), {:ci_watcher_update, issue_id, state_name})
      Application.get_env(:aiur, :ci_watcher_update_result, :ok)
    end

    def fetch_issue_states_by_ids(issue_ids) do
      issues = Application.get_env(:aiur, :ci_watcher_issues, [])
      {:ok, Enum.filter(issues, &(&1.id in issue_ids))}
    end

    defp recipient, do: Application.get_env(:aiur, :ci_watcher_recipient)
  end

  def fake_agent_loop do
    receive do
      _ -> fake_agent_loop()
    end
  end

  def blocker_ref, do: "refs/heads/aiur/99-dependency"
  def blocker_sha, do: String.duplicate("a", 40)

  # BranchRefStore persists through a disk-backed GenServer. Under full-suite
  # IO load a write can transiently fail; on failure it rolls the in-memory
  # state back and queues a retry (production recovers the same way via
  # PushRouting.reconcile_durable_unblocks). `await_settled/0` blocks on
  # that retry actually landing instead of guessing at a wall-clock
  # deadline, so a saturated box does not surface as a spurious failure of
  # an assertion that reads the store immediately.
  def reset_branch_refs do
    BranchRefStore.reset()
    :ok = BranchRefStore.await_settled()
  end

  def record_blocker_ref do
    BranchRefStore.record(blocker_ref(), blocker_sha())
    :ok = BranchRefStore.await_settled()
  end

  def assert_ready_unblock(expected) do
    :ok = BranchRefStore.await_settled()
    assert BranchRefStore.ready_unblock("99") == expected
  end

  def blocker_pause_fields do
    %{
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: "99", generation: 1}
    }
  end

  def control_issue(issue_id, identifier, state \\ "in-progress") do
    %Issue{
      id: issue_id,
      state: state,
      identifier: identifier,
      tracker_identity: tracker_identity(issue_id)
    }
  end

  def confirm_pending_control(state, issue_id, status) do
    request_id = state.control_lifecycle.pending[issue_id]
    request = state.control_lifecycle.records[request_id]

    assert {:noreply, next} =
             PauseResume.handle_worker_control_state(state, issue_id, status, %{
               request_id: request_id,
               generation: request.generation
             })

    next
  end

  def with_blocker_push(entry) do
    record_blocker_ref()
    entry
  end

  def pr_anchored_running_state(pr_number, agent_pid) do
    key = "pr-#{pr_number}"
    identifier = to_string(pr_number)

    %Orchestrator.State{
      running: %{
        key => %{
          pid: agent_pid,
          ref: nil,
          identifier: identifier,
          issue: %Issue{
            id: key,
            identifier: identifier,
            state: "pr-watch",
            pr_head_ref: "feature/login"
          },
          started_at: DateTime.utc_now(),
          control: %{status: :working}
        }
      },
      claimed: MapSet.new([key]),
      retry_attempts: %{key => %{attempt: 1}}
    }
  end

  def enable_pr_watch!(test_root) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "acme/widgets",
      workspace_root: test_root,
      pr_watch_enabled: true
    )
  end

  def capture_fetcher(test_pid) do
    fn inner ->
      fn pr_number ->
        send(test_pid, {:fetcher_called, pr_number})
        inner.(pr_number)
      end
    end
  end

  def empty_orchestrator_state do
    %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{},
      max_concurrent_agents: 6
    }
  end

  def restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  def restore_application_env(key, value), do: Application.put_env(:aiur, key, value)

  def human_review_running_state(issue_id, agent_pid) do
    %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: issue_id,
          issue: %Issue{
            id: issue_id,
            state: "in-progress",
            identifier: issue_id,
            tracker_identity: tracker_identity(issue_id)
          },
          started_at: DateTime.utc_now(),
          control: confirmed_control(:working)
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end

  def control_test_agent(test_pid) do
    spawn(fn -> control_test_agent_loop(test_pid) end)
  end

  def control_agent_barrier(agent_pid) do
    ref = make_ref()
    send(agent_pid, {:control_agent_barrier, ref})
    receive_barrier({:ci_wait_control, {:control_agent_barrier, ^ref}})
  end

  def confirmed_control(status) do
    %{
      status: status,
      application_confirmation: :confirmed,
      generation: 101,
      version: 0
    }
  end

  def tracker_identity(identifier) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: "I_kwDO#{identifier}",
      identifier: "101",
      reason: nil
    }
  end

  # Models a long-lived agent process: it forwards each control message to the
  # test and stays alive, so a paused runner (CI-wait) remains alive exactly as
  # a real agent would rather than exiting after one message.
  def control_test_agent_loop(test_pid) do
    receive do
      message ->
        send(test_pid, {:ci_wait_control, message})
        control_test_agent_loop(test_pid)
    end
  end

  def human_review_issue(issue_id) do
    %Issue{
      id: issue_id,
      identifier: issue_id,
      state: "human-review",
      title: "PR up for review",
      description: "",
      labels: []
    }
  end

  def datetime!(iso8601) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(iso8601)
    datetime
  end

  def drain_issue_comment_requests(acc) do
    receive do
      {:issue_comments_requested, id} -> drain_issue_comment_requests([id | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  # Override the running CodeOwners allowlist so `Sanitizer.stamp_author_trust/2`
  # treats `logins` as trusted for the duration of a command-scan test, then
  # restore the previous allowlist in the `after` block. Mirrors the
  # github_comments_poller test's `ensure_codeowners!` pattern.
  def trust_authors!(logins) do
    pid = Process.whereis(CodeOwners)
    previous = CodeOwners.snapshot(pid)
    Process.put(:command_scan_codeowners, %{pid: pid, previous: previous})
    allowlist = MapSet.new(Enum.map(logins, &String.downcase/1))
    :sys.replace_state(pid, fn state -> %{state | allowlist: allowlist} end)
    %{pid: pid, previous: previous}
  end

  def codeowners_state, do: Process.get(:command_scan_codeowners)

  def restore_trust!(nil), do: :ok

  def restore_trust!(%{pid: pid, previous: previous}) do
    if Process.alive?(pid) do
      :sys.replace_state(pid, &%{&1 | allowlist: MapSet.new(previous)})
    end

    Process.delete(:command_scan_codeowners)
    :ok
  end

  def empty_review_threads_response do
    review_threads_response([])
  end

  def review_threads_response(nodes) do
    {:ok,
     %{
       status: 200,
       body: %{
         "data" => %{
           "repository" => %{
             "pullRequest" => %{
               "reviewThreads" => %{
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                 "nodes" => nodes
               }
             }
           }
         }
       }
     }}
  end

  def review_thread_comment(id, login, body) do
    %{
      "databaseId" => id,
      "body" => body,
      "author" => %{"login" => login},
      "createdAt" => "2026-06-24T12:00:00Z",
      "updatedAt" => "2026-06-24T12:00:00Z"
    }
  end
end
