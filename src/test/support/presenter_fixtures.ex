defmodule AiurWeb.PresenterFixtures do
  @moduledoc false

  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.Orchestrator.{SnapshotStore, StatusReport}

  def running_entry(issue_id, identifier, status, issue_state \\ "In Progress") do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{
        id: issue_id,
        identifier: identifier,
        state: issue_state,
        title: "Row #{identifier}",
        url: "https://example.test/issues/#{identifier}"
      },
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

  def tracker_identity(identifier) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I_kwDO#{identifier}",
      identifier: identifier,
      reason: nil
    }
  end

  def publish_dashboard_snapshot(pid) do
    state = :sys.get_state(pid)
    :ok = SnapshotStore.publish(state.snapshot_key, StatusReport.snapshot_payload(state))
  end

  def merged_event do
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
