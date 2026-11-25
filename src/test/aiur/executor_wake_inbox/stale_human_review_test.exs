defmodule Aiur.ExecutorWakeInbox.StaleHumanReviewTest do
  use Aiur.TestSupport

  alias Aiur.Executor.Claims
  alias Aiur.ExecutorWakeInbox
  alias Aiur.ExecutorWakeInbox.StaleHumanReview
  alias Aiur.GitHub.ResourceStore

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-stale-human-review-wake")
    # Name the repo: resolved from origin, it is whatever an earlier test left
    # cached, and a cached nil makes every projection key nil (:invalid_key).
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/aiur", workspace_root: root)
    origin_key = {Aiur.GitHub.Config, :resolved_origin_repo}
    previous_origin = :persistent_term.get(origin_key, :unset)
    :persistent_term.put(origin_key, nil)

    opts = [
      name: __MODULE__,
      debounce_ms: 60_000,
      path: Path.join(root, "wakes.ndjson"),
      cursor_path: Path.join(root, "cursor.json"),
      pending_path: Path.join(root, "pending.json")
    ]

    on_exit(fn ->
      if previous_origin == :unset, do: :persistent_term.erase(origin_key), else: :persistent_term.put(origin_key, previous_origin)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{opts: opts}
  end

  test "drops and acknowledges a human-review wake after the ticket moves to ci-wait", %{opts: opts} do
    put_human_review_wake(opts)
    put_ticket_projection(42, "open", ["agent:ci-wait"])
    start_supervised!({ExecutorWakeInbox, with_state_reader(opts)})

    assert ExecutorWakeInbox.pending(__MODULE__) == []
    assert_state_read()
    assert ExecutorWakeInbox.cursor(__MODULE__) == 1
  end

  test "drops and acknowledges a human-review wake for a closed ticket", %{opts: opts} do
    put_human_review_wake(opts)
    put_ticket_projection(42, "closed", ["agent:human-review"])
    start_supervised!({ExecutorWakeInbox, with_state_reader(opts)})

    assert ExecutorWakeInbox.pending(__MODULE__) == []
    assert_state_read()
    assert ExecutorWakeInbox.cursor(__MODULE__) == 1
  end

  test "delivers a human-review wake while the live ticket remains in human-review", %{opts: opts} do
    put_human_review_wake(opts)
    put_ticket_projection(42, "open", ["agent:human-review"])
    start_supervised!({ExecutorWakeInbox, with_state_reader(opts)})

    assert [%{"wake_id" => 1, "action" => "human_review"}] = ExecutorWakeInbox.pending(__MODULE__)
    assert_state_read()
    assert ExecutorWakeInbox.cursor(__MODULE__) == 0
  end

  test "delivers a human-review wake when the live issue projection is unavailable", %{opts: opts} do
    put_human_review_wake(opts)
    start_supervised!({ExecutorWakeInbox, with_state_reader(opts)})

    assert [%{"wake_id" => 1, "action" => "human_review"}] = ExecutorWakeInbox.pending(__MODULE__)
    assert_state_read()
    assert ExecutorWakeInbox.cursor(__MODULE__) == 0
  end

  test "delivers a human-review wake when the live state reader raises", %{opts: opts} do
    put_human_review_wake(opts)
    start_supervised!({ExecutorWakeInbox, with_failing_state_reader(opts)})

    assert [%{"wake_id" => 1, "action" => "human_review"}] = ExecutorWakeInbox.pending(__MODULE__)
    assert_state_read()
    assert ExecutorWakeInbox.cursor(__MODULE__) == 0
  end

  test "delivers a human-review wake when the issue projection has no readable labels", %{opts: opts} do
    put_human_review_wake(opts)
    repo = Aiur.GitHub.Config.repo(Aiur.Config.settings!())
    :ok = ResourceStore.put_resource(ResourceStore.key_for_repo(:issue, repo, 42), %{"number" => 42, "state" => "open"})
    start_supervised!({ExecutorWakeInbox, with_state_reader(opts)})

    assert [%{"wake_id" => 1, "action" => "human_review"}] = ExecutorWakeInbox.pending(__MODULE__)
    assert_state_read()
    assert ExecutorWakeInbox.cursor(__MODULE__) == 0
  end

  # open-games, 2026-11-20: about 600 stale human-review wakes sat behind one live
  # wake. Only a stale prefix was ever trimmed, so every read checked and logged
  # all of them again, 25 times a minute, and kept the inbox busy.
  test "a stale wake behind a live one is checked once, not on every read", %{opts: opts} do
    write_wakes(opts, [{1, "42"}, {2, "43"}])
    put_ticket_projection(42, "open", ["agent:human-review"])
    put_ticket_projection(43, "open", ["agent:ci-wait"])
    start_supervised!({ExecutorWakeInbox, with_state_reader(opts)})

    for _read <- 1..3 do
      assert [%{"wake_id" => 1}] = ExecutorWakeInbox.pending(__MODULE__)
    end

    assert_receive {:human_review_state_read, 2}, 1_000
    refute_receive {:human_review_state_read, 2}, 100
  end

  test "once the live wake is acknowledged the stale one behind it is passed too", %{opts: opts} do
    write_wakes(opts, [{1, "42"}, {2, "43"}])
    put_ticket_projection(42, "open", ["agent:human-review"])
    put_ticket_projection(43, "open", ["agent:ci-wait"])
    start_supervised!({ExecutorWakeInbox, with_state_reader(opts)})

    assert [live] = ExecutorWakeInbox.pending(__MODULE__)
    {:ok, _claim} = Claims.claim("stale-behind-live")
    assert :ok = ExecutorWakeInbox.acknowledge_as("stale-behind-live", [live], __MODULE__)
    assert ExecutorWakeInbox.pending(__MODULE__) == []
    assert ExecutorWakeInbox.cursor(__MODULE__) == 2
  end

  defp with_state_reader(opts) do
    caller = self()

    reader = fn record ->
      send(caller, {:human_review_state_read, record["wake_id"]})
      StaleHumanReview.current_state(record)
    end

    Keyword.put(opts, :human_review_state_reader, reader)
  end

  defp with_failing_state_reader(opts) do
    caller = self()

    reader = fn record ->
      send(caller, {:human_review_state_read, record["wake_id"]})
      raise "issue state read failed"
    end

    Keyword.put(opts, :human_review_state_reader, reader)
  end

  defp assert_state_read do
    assert_receive {:human_review_state_read, 1}, 1_000
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

  defp write_wakes(opts, wakes) do
    File.mkdir_p!(Path.dirname(opts[:path]))
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    lines =
      for {id, ticket} <- wakes do
        Jason.encode!(%{
          "wake_id" => id,
          "event_id" => 100 + id,
          "ticket" => ticket,
          "topic" => "ticket.#{ticket}.agent.handoff.human_review",
          "topic_class" => "ticket.agent.handoff.human_review",
          "action" => "human_review",
          "count" => 1,
          "first_seen_at" => now,
          "last_seen_at" => now
        }) <> "\n"
      end

    File.write!(opts[:path], lines)
  end
end
