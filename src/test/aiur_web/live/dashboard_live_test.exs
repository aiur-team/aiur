defmodule AiurWeb.DashboardLiveTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.RecentMerge
  alias AiurWeb.{ControlCenterPresenter, DashboardLive, Presenter}

  defp render_payload(fleet_payload, opts \\ []) do
    payload =
      Keyword.get_lazy(opts, :payload, fn ->
        ControlCenterPresenter.state_payload(
          :unused,
          1,
          fleet_fun: fn -> fleet_payload end,
          decisions_fun: fn -> [] end
        )
      end)

    selected_decision_id = Keyword.get(opts, :selected_decision_id)
    selected_decision = Enum.find(payload.decisions, &(&1.decision_id == selected_decision_id))

    assigns = %{
      payload: payload,
      now: DateTime.utc_now(),
      agent_log_modal: nil,
      drafts: %{},
      chat_errors: %{},
      writable: false,
      live_action: Keyword.get(opts, :live_action, :index),
      decision_filter: :all,
      selected_decision_id: selected_decision_id,
      selected_decision: selected_decision
    }

    assigns
    |> DashboardLive.render()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  test "renders explicit waiting reasons, staleness, CI/PR, and the idle bucket" do
    orchestrator_name = Module.concat(__MODULE__, :RenderOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    ci_wait_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: "MT-900",
      issue: %Issue{id: "issue-ci-wait", identifier: "MT-900", state: "ci-wait", title: "Row MT-900"},
      worker_host: nil,
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :paused},
      session_id: "thread-MT-900",
      codex_app_server_pid: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now(),
      last_codex_timestamp: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      paused_reason: :ci_wait
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"issue-ci-wait" => ci_wait_entry},
          retry_attempts: %{
            "issue-retry" => %{
              attempt: 2,
              timer_ref: nil,
              due_at_ms: System.monotonic_time(:millisecond) + 5_000,
              identifier: "MT-902",
              error: "temporary failure"
            }
          },
          ci_lifecycle: %{
            state.ci_lifecycle
            | poll_cache: %{"MT-900" => %{decision: :pending, pr_number: 77, head_sha: "deadbeef"}}
          },
          last_polled_issues: %{
            "issue-ci-wait" => %Issue{id: "issue-ci-wait", identifier: "MT-900", state: "ci-wait"},
            "issue-idle" => %Issue{id: "issue-idle", identifier: "MT-901", state: "human-review", title: "Idle review"},
            "issue-retry" => %Issue{id: "issue-retry", identifier: "MT-902", state: "rework", title: "Retrying"}
          }
      }
    end)

    payload = Presenter.state_payload(orchestrator_name, 1_000)
    html = render_payload(payload)

    assert html =~ "MT-900"
    assert html =~ "Waiting for ci"
    assert html =~ "PR #77 Pending"
    assert html =~ "Review not started"
    assert html =~ "MT-901"
    assert html =~ "Waiting for review"
    assert html =~ "Review awaiting"
    assert html =~ "Fleet state"
    assert html =~ "MT-902"
    assert html =~ "Backing off"
  end

  test "renders the approved decision surface with a stable escaped deep link" do
    fleet_payload = %{
      generated_at: "2026-07-12T12:00:00Z",
      counts: %{running: 0, retrying: 0, idle: 0},
      running: [],
      retrying: [],
      idle: [],
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    decision = %{
      decision_id: "dec-safe-link",
      version: 1,
      ticket: %{identifier: "AIUR-987", title: "Operator Control Center", url: "https://example.test/issues/987"},
      source: %{agent_id: "agent-987", session_id: "session-987", event_id: "event-987"},
      kind: "architecture",
      authority: :human_required,
      urgency: :critical,
      blocking: true,
      reversibility: :reversible,
      question: "Should the component split ship?",
      context: %{short: "Use the approved design", long_markdown: "**safe markdown** <script>alert('no')</script>"},
      options: [],
      recommendation: nil,
      consequence_of_delay: "The agent remains paused.",
      artifacts: [],
      created_at: ~U[2026-07-12 12:00:00Z],
      source_created_at: nil,
      lifecycle: :recorded
    }

    payload =
      fleet_payload
      |> ControlCenterPresenter.compose([], [], %{merges: [], health: :ready, reconciliation: %{status: :complete, partial?: false}})
      |> Map.put(:decisions, [decision])
      |> Map.put(:overview, %{blocking_decisions: 1, running: 0, queued_or_retrying: 0, merged_this_run: 0})

    inbox_html = render_payload(fleet_payload, payload: payload, live_action: :decisions)
    detail_html = render_payload(fleet_payload, payload: payload, live_action: :decision, selected_decision_id: decision.decision_id)

    assert inbox_html =~ ~s(src="/aiur-logo.png")
    assert inbox_html =~ ~s(href="/decisions/dec-safe-link")
    assert inbox_html =~ "Decision inbox"
    assert detail_html =~ "Recorded"
    assert detail_html =~ "Dispatch pending"
    assert detail_html =~ "The agent remains paused."
    assert detail_html =~ "&lt;script&gt;alert(&#39;no&#39;)&lt;/script&gt;"
    refute detail_html =~ "<script>alert('no')</script>"
    assert detail_html =~ "Read-only mode · mutation controls are hidden."
  end

  test "renders durable decision history, honest merge provenance, and the analytics link during a snapshot outage" do
    history = [
      history_entry("dec-human", :human_operator, "Human operator", "<script>alert('decision')</script>"),
      history_entry("dec-supervisor", :supervising_agent, "Supervising agent", "Approve the fallback?")
    ]

    assert {:ok, merge} =
             RecentMerge.from_github_event(merged_event(),
               live?: true,
               run_id: "run-observer-123456789",
               now: ~U[2026-07-12 18:01:00Z]
             )

    telemetry_path = Path.expand("../../fixtures/run_telemetry/session-a/telemetry.ndjson", __DIR__)
    assert File.regular?(telemetry_path), telemetry_path

    payload =
      Presenter.state_payload(Module.concat(__MODULE__, :MissingHistoryOrchestrator), 5,
        decision_history_fun: fn -> history end,
        recent_merge_snapshot_fun: fn ->
          %{
            merges: [merge],
            health: :writable,
            reconciliation: %{status: :partial, partial?: true, pages_fetched: 5}
          }
        end,
        telemetry_file_fun: fn -> telemetry_path end
      )

    assert payload.analytics.available?, inspect(payload.analytics)
    html = render_payload(payload)

    assert html =~ "Snapshot unavailable"
    assert html =~ "Decision history"
    assert html =~ "Human operator"
    assert html =~ "Supervising agent"
    assert html =~ "&lt;script&gt;alert"
    refute html =~ "<script>alert"
    assert html =~ "Recent repository merges"
    assert html =~ "Observed live"
    assert html =~ "Observer run run-observer"
    assert html =~ "No ticket attribution"
    assert html =~ "5-page cap"
    assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
    refute html =~ "<img src=x"
    assert html =~ ~s(href="/analytics")
    assert html =~ "Open analytics report"
  end

  defp history_entry(id, actor_type, actor_label, question) do
    %{
      decision_id: id,
      ticket: %{identifier: "983", title: "OCC-6", url: "https://github.com/owner/repo/issues/983"},
      question: question,
      source_version: 1,
      changed_at: "2026-07-12T18:00:00Z",
      change: :requested,
      actor: %{type: actor_type, id: actor_label, label: actor_label},
      choice: nil,
      rationale: nil,
      dispatch_result: nil,
      acknowledgement_result: nil,
      revision_of: nil,
      superseded_by: nil,
      revised?: false
    }
  end

  defp merged_event do
    %{
      "id" => "dashboard-merge",
      "type" => "PullRequestEvent",
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "closed",
        "pull_request" => %{
          "number" => 42,
          "title" => "<img src=x onerror=alert(1)>",
          "body" => "Repository merge",
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
