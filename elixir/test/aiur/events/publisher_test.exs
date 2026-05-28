defmodule Aiur.Events.PublisherTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Workflow

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur",
      tracker_bot_account: "aiur-bot"
    )

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end

      # Reset tracked_fn to default (accept all)
      Publisher.set_tracked_fn(fn _ -> true end)
    end)

    :ok
  end

  describe "publish/3" do
    test "publishes a happy-path event for a tracked issue" do
      :ok = Exchange.subscribe("ticket.42.branch.push")
      # The orchestrator subscribes to `ticket.*.branch.push` at boot
      # for blockee auto-resume, so the subscriber count includes it
      # alongside the per-test subscriber.
      assert {:ok, id, count} = Publisher.publish("ticket.42.branch.push", %{sha: "abc"})
      assert is_integer(id)
      assert count >= 1
      assert_receive {:event, %{id: ^id, sha: "abc", topic: "ticket.42.branch.push"}}, 500
    end

    test "drops events whose actor is the bot_account" do
      :ok = Exchange.subscribe("ticket.42.#")
      assert :filtered = Publisher.publish("ticket.42.branch.push", %{}, actor: "aiur-bot")
      refute_receive {:event, _}, 100
    end

    test "case-insensitive bot self-loop filter" do
      :ok = Exchange.subscribe("ticket.42.#")
      assert :filtered = Publisher.publish("ticket.42.branch.push", %{}, actor: "AIUR-BOT")
    end

    test "drops events for untracked issues" do
      Publisher.set_tracked_fn(fn n -> n == 42 end)

      :ok = Exchange.subscribe("ticket.99.#")
      assert :filtered = Publisher.publish("ticket.99.branch.push", %{}, issue_number: 99)
      refute_receive {:event, _}, 100
    end

    test "allows events with nil issue_number (system topics)" do
      :ok = Exchange.subscribe("system.main.branch.push")
      assert {:ok, _id, 1} = Publisher.publish("system.main.branch.push", %{sha: "abc"})
      assert_receive {:event, _}, 500
    end
  end

  describe "push dedup" do
    test "same (repo, ref, sha) triple within window is deduped" do
      :ok = Exchange.subscribe("ticket.42.branch.push")

      sha = "ded-#{System.unique_integer([:positive])}"
      dedup = {"owner/repo", "refs/heads/aiur/42", sha}
      assert {:ok, _, _} = Publisher.publish("ticket.42.branch.push", %{sha: sha}, dedup_key: dedup)
      assert :deduped = Publisher.publish("ticket.42.branch.push", %{sha: sha}, dedup_key: dedup)

      assert_receive {:event, _}, 500
      refute_receive {:event, _}, 100
    end

    test "different sha for the same ref is NOT deduped" do
      :ok = Exchange.subscribe("ticket.42.branch.push")

      sha_a = "abc-#{System.unique_integer([:positive])}"
      sha_b = "def-#{System.unique_integer([:positive])}"
      d1 = {"owner/repo", "refs/heads/aiur/42", sha_a}
      d2 = {"owner/repo", "refs/heads/aiur/42", sha_b}

      assert {:ok, _, _} = Publisher.publish("ticket.42.branch.push", %{sha: sha_a}, dedup_key: d1)
      assert {:ok, _, _} = Publisher.publish("ticket.42.branch.push", %{sha: sha_b}, dedup_key: d2)

      assert_receive {:event, %{sha: ^sha_a}}, 500
      assert_receive {:event, %{sha: ^sha_b}}, 500
    end

    test "record_push/3 + push_seen?/3 round-trip" do
      assert :ok = Publisher.record_push("owner/repo", "refs/heads/main", "xyz")
      assert Publisher.push_seen?("owner/repo", "refs/heads/main", "xyz")
      refute Publisher.push_seen?("owner/repo", "refs/heads/main", "different")
    end
  end
end
