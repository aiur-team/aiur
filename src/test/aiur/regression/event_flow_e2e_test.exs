defmodule Aiur.Regression.EventFlowE2eTest do
  @moduledoc """
  End-to-end wiring test for the Aiur event-foundation pipeline.

  Verifies the full publish → exchange → subscription store → enqueue
  → render path for a scripted 3-ticket scenario. **Does not** spin up
  real agents — uses the SubscriptionStore directly + a stub enqueue
  closure that captures what the AgentRunner would have seen.

  Scope: this catches regressions in any of the U1-U18 module
  boundaries (Topic matcher, Exchange, Publisher, IdGenerator,
  SubscriptionStore, dispatch through to enqueue). Stuff that depends
  on a real agent runner or opencode pane is out of scope here — that
  is the manual `aiur --test` workflow's job.
  """

  use Aiur.TestSupport

  alias Aiur.Workflow

  alias Aiur.Events.{Exchange, GithubFirehose, Publisher, SubscriptionStore}

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "aiur_e2e_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    original_log_file = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(tmp_dir, "aiur.log"))

    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur"
    )

    # Persistent_term outlives test boundaries; explicit reset.
    Publisher.set_tracked_fn(fn _ -> true end)

    # Stub the enqueue closure so we see what would have reached the
    # AgentRunner without spinning up the orchestrator + queue store.
    test_pid = self()

    SubscriptionStore.set_enqueue_fn(fn id, event ->
      send(test_pid, {:enqueued, id, event})
      :ok
    end)

    # Reset tracked_fn so all events pass the contamination filter
    # unless a specific test overrides this.
    Publisher.set_tracked_fn(fn _ -> true end)

    on_exit(fn ->
      SubscriptionStore.set_enqueue_fn(nil)
      Publisher.set_tracked_fn(fn _ -> true end)

      restore_env("GITHUB_TOKEN", prev_token)

      if original_log_file do
        Application.put_env(:aiur, :log_file, original_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end

      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "3-ticket coordination chain" do
    test "ticket 2 receives ticket 1's branch.push via subscribe + publish" do
      ticket_2 = "e2e-2-#{System.unique_integer([:positive])}"

      :ok = SubscriptionStore.attach(ticket_2)
      :ok = SubscriptionStore.add_subscription(ticket_2, "ticket.1.#", "auto:blocked_by(1)")

      # Allow Exchange.subscribe to register in the binding table
      Process.sleep(50)

      Publisher.publish(
        "ticket.1.branch.push",
        %{sha: "abc-#{System.unique_integer([:positive])}", actor: "alice"},
        issue_number: 1
      )

      assert_receive {:enqueued, ^ticket_2, %{topic: "ticket.1.branch.push", actor: "alice"}},
                     500

      :ok = SubscriptionStore.stop(ticket_2)
    end

    test "ticket 3 (no blocker) does NOT receive ticket 1's push by default" do
      ticket_3 = "e2e-3-#{System.unique_integer([:positive])}"

      :ok = SubscriptionStore.attach(ticket_3)
      # No subscription added — ticket 3 has not declared #1 as a blocker
      Process.sleep(50)

      Publisher.publish("ticket.1.branch.push", %{sha: "abc"}, issue_number: 1)

      refute_receive {:enqueued, ^ticket_3, _}, 200
      :ok = SubscriptionStore.stop(ticket_3)
    end

    test "ticket 3 mid-work declare_blocker pattern: subscribe THEN see events" do
      ticket_3 = "e2e-3-late-#{System.unique_integer([:positive])}"

      :ok = SubscriptionStore.attach(ticket_3)
      Process.sleep(50)

      # First push — ticket 3 NOT yet subscribed; should be dropped
      Publisher.publish("ticket.1.branch.push", %{sha: "first"}, issue_number: 1)
      refute_receive {:enqueued, ^ticket_3, _}, 100

      # Mid-work: ticket 3 declares blocker → adds subscription
      :ok = SubscriptionStore.add_subscription(ticket_3, "ticket.1.#", "manual:late-discovery")
      Process.sleep(50)

      # Next push reaches ticket 3
      Publisher.publish("ticket.1.branch.push", %{sha: "second"}, issue_number: 1)
      assert_receive {:enqueued, ^ticket_3, %{sha: "second"}}, 500

      :ok = SubscriptionStore.stop(ticket_3)
    end
  end

  describe "GithubFirehose end-to-end" do
    test "PullRequestEvent from firehose reaches subscribed ticket's enqueue" do
      ticket_2 = "e2e-fh-#{System.unique_integer([:positive])}"

      :ok = SubscriptionStore.attach(ticket_2)
      :ok = SubscriptionStore.add_subscription(ticket_2, "ticket.42.pr.opened", "test")
      Process.sleep(50)

      stub_firehose = fn _req ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("z1")}, {"X-Poll-Interval", "60"}],
           body: [
             %{
               "type" => "PullRequestEvent",
               "actor" => %{"login" => "bob"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "action" => "opened",
                 "pull_request" => %{
                   "number" => 4242,
                   "head" => %{"ref" => "aiur/42", "sha" => "fh-#{System.unique_integer([:positive])}"}
                 }
               }
             }
           ]
         }}
      end

      {:ok, %{count: 1}} = GithubFirehose.poll(request_fun: stub_firehose)

      assert_receive {:enqueued, ^ticket_2, %{topic: "ticket.42.pr.opened"}}, 500

      :ok = SubscriptionStore.stop(ticket_2)
    end
  end

  describe "contamination filter" do
    test "untracked issue's events are dropped by Publisher.tracked_fn" do
      ticket_2 = "e2e-tracked-#{System.unique_integer([:positive])}"

      :ok = SubscriptionStore.attach(ticket_2)
      :ok = SubscriptionStore.add_subscription(ticket_2, "ticket.99.#", "test")
      Process.sleep(50)

      Publisher.set_tracked_fn(fn n -> to_string(n) != "99" end)

      Publisher.publish("ticket.99.branch.push", %{sha: "ignored"}, issue_number: 99)

      refute_receive {:enqueued, _, _}, 200
      :ok = SubscriptionStore.stop(ticket_2)
    end
  end

  describe "Exchange topic patterns" do
    test "ticket.<id>.# matches every surface for the ticket" do
      ticket_2 = "e2e-pat-#{System.unique_integer([:positive])}"

      :ok = SubscriptionStore.attach(ticket_2)
      :ok = SubscriptionStore.add_subscription(ticket_2, "ticket.55.#", "test")
      Process.sleep(50)

      for topic <- ["ticket.55.branch.push", "ticket.55.pr.opened", "ticket.55.agent.decision.foo"] do
        Publisher.publish(topic, %{topic_emitted: topic}, issue_number: 55)
      end

      received =
        for _ <- 1..3 do
          receive do
            {:enqueued, ^ticket_2, event} -> Map.get(event, :topic_emitted) || Map.get(event, :topic)
          after
            500 -> nil
          end
        end

      assert Enum.sort(received) ==
               Enum.sort([
                 "ticket.55.branch.push",
                 "ticket.55.pr.opened",
                 "ticket.55.agent.decision.foo"
               ])

      :ok = SubscriptionStore.stop(ticket_2)
    end
  end
end
