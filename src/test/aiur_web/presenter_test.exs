defmodule AiurWeb.PresenterTest do
  use Aiur.TestSupport

  alias Aiur.Events.SubscriptionStore
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.RecentMerge
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
      |> Map.put(:paused_reason, :ci_wait)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"issue-ci-wait" => ci_wait_entry},
          retry_attempts: %{
            "mt-701" => %{attempt: 1, timer_ref: nil, due_at_ms: System.monotonic_time(:millisecond) + 5_000, identifier: "MT-701"}
          },
          ci_lifecycle: %{
            state.ci_lifecycle
            | poll_cache: %{
                "MT-700" => %{decision: :pending, pr_number: 55, head_sha: "abc123"},
                "MT-702" => %{decision: :passed, pr_number: 56, head_sha: "def456"}
              }
          },
          last_polled_issues: %{
            "issue-ci-wait" => %Issue{id: "issue-ci-wait", identifier: "MT-700", state: "ci-wait"},
            "mt-701" => %Issue{id: "mt-701", identifier: "MT-701", state: "rework", title: "Retrying"},
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
    assert retry_row.state == "rework"
    assert retry_row.waiting_reason == :backing_off
    assert retry_row.open_decision_count == 0
    assert retry_row.ci == nil
    assert retry_row.review == :not_started

    assert [idle_row] = payload.idle
    assert idle_row.issue_identifier == "MT-702"
    assert idle_row.waiting_reason == :waiting_for_review
    assert idle_row.ci == %{decision: :passed, pr_number: 56, head_sha: "def456"}
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

  test "durable history and outcomes remain visible when the orchestrator is unavailable" do
    telemetry_path = Path.join(System.tmp_dir!(), "presenter-telemetry-#{System.unique_integer([:positive])}.ndjson")
    File.write!(telemetry_path, "")
    on_exit(fn -> File.rm(telemetry_path) end)

    decision = %{
      decision_id: "dec-history",
      ticket: %{identifier: "983", title: "OCC-6", url: nil},
      question: "Ship it?",
      source_version: 1,
      changed_at: "2026-07-12T18:00:00Z",
      change: :requested,
      actor: %{type: :human_operator, id: "operator-1", label: "Operator"},
      choice: nil,
      rationale: nil,
      dispatch_result: nil,
      acknowledgement_result: nil,
      revision_of: nil,
      superseded_by: nil,
      revised?: false
    }

    assert {:ok, merge} =
             RecentMerge.from_github_event(merged_event(),
               live?: false,
               now: ~U[2026-07-12 18:01:00Z]
             )

    payload =
      Presenter.state_payload(Module.concat(__MODULE__, :MissingOrchestrator), 5,
        decision_history_fun: fn -> [decision] end,
        recent_merge_snapshot_fun: fn ->
          %{
            merges: [merge],
            health: :writable,
            reconciliation: %{status: :partial, partial?: true, pages_fetched: 5}
          }
        end,
        telemetry_file_fun: fn -> telemetry_path end
      )

    assert payload.error.code == "snapshot_unavailable"
    assert payload.decision_history == %{status: :available, entries: [decision], message: nil}
    assert [recent] = payload.recent_merges.entries
    assert recent.number == 42
    assert recent.ticket_id == nil
    assert payload.recent_merges.reconciliation.partial?

    assert payload.analytics == %{
             available?: true,
             path: "/analytics",
             message: "Open the separate durable telemetry report."
           }
  end

  test "an unavailable optional provider does not hide the other durable section" do
    payload =
      Presenter.state_payload(Module.concat(__MODULE__, :MissingProvidersOrchestrator), 5,
        decision_history_fun: fn -> raise "offline" end,
        recent_merge_snapshot_fun: fn ->
          %{
            merges: [],
            health: :writable,
            reconciliation: %{status: :complete, partial?: false, pages_fetched: 1}
          }
        end,
        telemetry_file_fun: fn -> "/definitely/missing/telemetry.ndjson" end
      )

    assert payload.decision_history.status == :unavailable
    assert payload.recent_merges.status == :available
    refute payload.analytics.available?
  end

  test "the recent repository merge projection stays bounded" do
    assert {:ok, merge} =
             RecentMerge.from_github_event(merged_event(),
               live?: false,
               now: ~U[2026-07-12 18:01:00Z]
             )

    merges =
      Enum.map(1..51, fn number ->
        %{merge | id: "owner/repo##{number}", number: number, url: "https://github.com/owner/repo/pull/#{number}"}
      end)

    payload =
      Presenter.state_payload(Module.concat(__MODULE__, :MissingBoundedOrchestrator), 5,
        decision_history_fun: fn -> [] end,
        recent_merge_snapshot_fun: fn ->
          %{
            merges: merges,
            health: :writable,
            reconciliation: %{status: :complete, partial?: false, pages_fetched: 1}
          }
        end,
        telemetry_file_fun: fn -> "/definitely/missing/telemetry.ndjson" end
      )

    assert length(payload.recent_merges.entries) == 50
    assert Enum.map(payload.recent_merges.entries, & &1.number) == Enum.to_list(1..50)
  end

  defp merged_event do
    %{
      "id" => "presenter-merge",
      "type" => "PullRequestEvent",
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "closed",
        "pull_request" => %{
          "number" => 42,
          "title" => "Merged feature",
          "body" => "Repository-level outcome",
          "html_url" => "https://github.com/owner/repo/pull/42",
          "merged" => true,
          "merged_at" => "2026-07-12T18:00:00Z",
          "head" => %{"ref" => "release/2026-07", "sha" => "head-42"},
          "merged_by" => %{"login" => "merger"}
        }
      }
    }
  end
end
