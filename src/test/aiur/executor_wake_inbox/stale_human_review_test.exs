defmodule Aiur.ExecutorWakeInbox.StaleHumanReviewTest do
  use Aiur.TestSupport

  alias Aiur.ExecutorWakeInbox
  alias Aiur.GitHub.ResourceStore

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-stale-human-review-wake")

    opts = [
      name: __MODULE__,
      debounce_ms: 60_000,
      path: Path.join(root, "wakes.ndjson"),
      cursor_path: Path.join(root, "cursor.json"),
      pending_path: Path.join(root, "pending.json")
    ]

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{opts: opts}
  end

  test "drops and acknowledges a human-review wake after the ticket moves to ci-wait", %{opts: opts} do
    put_human_review_wake(opts)
    put_ticket_projection(42, "open", ["agent:ci-wait"])
    start_supervised!({ExecutorWakeInbox, opts})

    assert ExecutorWakeInbox.pending(__MODULE__) == []
    assert ExecutorWakeInbox.cursor(__MODULE__) == 1
  end

  test "drops and acknowledges a human-review wake for a closed ticket", %{opts: opts} do
    put_human_review_wake(opts)
    put_ticket_projection(42, "closed", ["agent:human-review"])
    start_supervised!({ExecutorWakeInbox, opts})

    assert ExecutorWakeInbox.pending(__MODULE__) == []
    assert ExecutorWakeInbox.cursor(__MODULE__) == 1
  end

  test "delivers a human-review wake while the live ticket remains in human-review", %{opts: opts} do
    put_human_review_wake(opts)
    put_ticket_projection(42, "open", ["agent:human-review"])
    start_supervised!({ExecutorWakeInbox, opts})

    assert [%{"wake_id" => 1, "action" => "human_review"}] = ExecutorWakeInbox.pending(__MODULE__)
    assert ExecutorWakeInbox.cursor(__MODULE__) == 0
  end

  test "delivers a human-review wake when the live issue projection is unavailable", %{opts: opts} do
    put_human_review_wake(opts)
    start_supervised!({ExecutorWakeInbox, opts})

    assert [%{"wake_id" => 1, "action" => "human_review"}] = ExecutorWakeInbox.pending(__MODULE__)
    assert ExecutorWakeInbox.cursor(__MODULE__) == 0
  end

  test "delivers a human-review wake when the issue projection has no readable labels", %{opts: opts} do
    put_human_review_wake(opts)
    repo = Aiur.GitHub.Config.repo(Aiur.Config.settings!())
    :ok = ResourceStore.put_resource(ResourceStore.key_for_repo(:issue, repo, 42), %{"number" => 42, "state" => "open"})
    start_supervised!({ExecutorWakeInbox, opts})

    assert [%{"wake_id" => 1, "action" => "human_review"}] = ExecutorWakeInbox.pending(__MODULE__)
    assert ExecutorWakeInbox.cursor(__MODULE__) == 0
  end

  defp put_human_review_wake(opts) do
    File.mkdir_p!(Path.dirname(opts[:path]))

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    wake = %{
      "wake_id" => 1,
      "event_id" => 42,
      "ticket" => "42",
      "topic" => "ticket.42.agent.handoff.human_review",
      "topic_class" => "ticket.agent.handoff.human_review",
      "action" => "human_review",
      "count" => 1,
      "first_seen_at" => now,
      "last_seen_at" => now
    }

    File.write!(opts[:path], Jason.encode!(wake) <> "\n")
  end

  defp put_ticket_projection(number, state, state_labels) do
    repo = Aiur.GitHub.Config.repo(Aiur.Config.settings!())
    issue_key = ResourceStore.key_for_repo(:issue, repo, number)
    labels_key = ResourceStore.key_for_repo(:issue_labels, repo, number)
    labels = Enum.map(state_labels, &%{"name" => &1})
    :ok = ResourceStore.put_resource(issue_key, %{"number" => number, "state" => state, "labels" => labels})
    :ok = ResourceStore.put_resource(labels_key, labels)
  end
end
