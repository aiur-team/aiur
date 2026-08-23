defmodule Aiur.Events.WebhookPollReconciliationTest do
  @moduledoc """
  The poll sweep as a reconciliation pass over the webhook pipe (#2069).

  Two requirements pull against each other and the tension is the point:

    * a comment the webhook delivered must be processed **once**, not again by
      the next sweep, and
    * a comment whose delivery was **lost** must still be recovered — 9 of 100
      measured deliveries returned 502 during a daemon restart, GitHub retried
      none, and none arrived later.

  A blanket "skip polling when the repo is webhook-backed" satisfies the first
  and silently loses the second. Suppressing per *resource identity* satisfies
  both: the sweep always runs and always reads, and only the individual comments
  some pipe already processed are held back.
  """

  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, GithubCommentsPoller, GithubWebhook}
  alias Aiur.GitHub.ResourceStore

  @repo "owner/repo"
  @topic "ticket.42.issue.commented"

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: @repo)

    dir = Path.join(System.tmp_dir!(), "aiur-reconciliation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    store_path = Path.join(dir, "github_resources.json")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)
      Application.delete_env(:aiur, :github_resource_store_path)

      if Process.whereis(ResourceStore) == nil do
        Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
      end

      ResourceStore.reset()
      clear_replay_window()
      File.rm_rf(dir)
    end)

    {:ok, store_path: store_path}
  end

  describe "a comment the webhook delivered" do
    # Acceptance criterion 3. The sweep still reads the comment back — that read
    # is what makes criterion 4 possible — but it must not publish it a second
    # time and wake the agent twice for one human comment.
    test "is published once by the delivery and not again by the sweep" do
      :ok = Exchange.subscribe(@topic)

      assert %{status: :published, published: [@topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(9001, "review this"), repo: @repo)

      assert %{comment: %{"id" => 9001}} = await_event(@topic)

      # The sweep reads the very same comment back from GitHub.
      {calls, result} = sweep([comment(9001, "review this")])

      assert {:ok, %{count: 0}} = result
      # The read still happened: this is reconciliation, not suppression of the
      # sweep itself.
      assert length(calls) == 1
      refute_event(@topic)
    end

    # The in-memory replay window empties on every daemon restart, which is
    # exactly when this matters: the 502s that lost deliveries were measured
    # *during* a restart, so the sweep that runs right after one is the sweep
    # most likely to re-read a comment the pre-restart daemon already handled.
    test "stays suppressed across a restart of the in-memory replay window" do
      :ok = Exchange.subscribe(@topic)

      assert %{status: :published, published: [@topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(9010, "before the restart"), repo: @repo)

      assert %{comment: %{"id" => 9010}} = await_event(@topic)

      clear_replay_window()

      {_calls, result} = sweep([comment(9010, "before the restart")])

      assert {:ok, %{count: 0}} = result
      refute_event(@topic)
    end
  end

  # An operator editing a comment to correct an agent's instructions is a normal
  # workflow here. A GitHub comment is mutable: an edit keeps the id and moves
  # only `updated_at`, so suppressing on identity alone would swallow that edit
  # for the store's full 72-hour retention, across restarts.
  #
  # Every case here first expires the volatile replay window. That is not test
  # convenience — it *is* the scenario. `Publisher`'s in-memory window suppresses
  # any repeat for an hour and always did, so an edit made minutes later is
  # suppressed on `main` too and proves nothing about this change. The regression
  # only exists past that hour, where the durable store is the sole remaining
  # gate, so these cases start where it is the only thing deciding.
  describe "an edited comment, more than an hour after posting" do
    test "re-publishes when the sweep sees a changed updated_at" do
      :ok = Exchange.subscribe(@topic)

      assert %{status: :published, published: [@topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(9020, "run the wrong thing"), repo: @repo)

      assert %{comment: %{"body" => "run the wrong thing"}} = await_event(@topic)
      clear_replay_window()

      # Operator corrects the instruction. Same comment id, later updated_at.
      {_calls, result} = sweep([comment(9020, "run the right thing", "2026-06-24T14:00:00Z")])

      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"body" => "run the right thing"}} = await_event(@topic)
    end

    test "re-publishes when the edit itself arrives as a delivery" do
      :ok = Exchange.subscribe(@topic)

      assert %{status: :published, published: [@topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(9021, "first"), repo: @repo)

      assert %{comment: %{"body" => "first"}} = await_event(@topic)
      clear_replay_window()

      edited =
        9021
        |> delivery("corrected")
        |> Map.put("action", "edited")
        |> put_in(["comment", "updated_at"], "2026-06-24T14:00:00Z")

      assert %{status: :published, published: [@topic]} =
               GithubWebhook.handle_delivery("issue_comment", edited, repo: @repo)

      assert %{comment: %{"body" => "corrected"}} = await_event(@topic)
    end

    # The other half of the contract, and the reason this is a version check
    # rather than a shortened TTL: with the volatile window gone, an *unchanged*
    # comment re-read by the sweep is still suppressed, however many cycles run
    # over it. Shortening the TTL would have bought the edit back by giving up
    # exactly this.
    test "an unchanged re-fetch is still suppressed once the window has expired" do
      :ok = Exchange.subscribe(@topic)

      assert %{status: :published, published: [@topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(9022, "unchanged"), repo: @repo)

      assert %{comment: %{"id" => 9022}} = await_event(@topic)
      clear_replay_window()

      for _cycle <- 1..3 do
        assert {:ok, %{count: 0}} = elem(sweep([comment(9022, "unchanged")]), 1)
      end

      refute_event(@topic)
    end

    test "a version change is what unsuppresses, not the passage of time" do
      key = ResourceStore.key_for_repo(:issue_comment, @repo, 9023)

      ResourceStore.mark_processed(key, :webhook, "2026-06-24T12:00:00Z")

      assert ResourceStore.processed?(key, "2026-06-24T12:00:00Z")
      refute ResourceStore.processed?(key, "2026-06-24T14:00:00Z")

      # Re-marking at the new version suppresses that version in turn, so an
      # edit wakes the agent once rather than every cycle thereafter.
      ResourceStore.mark_processed(key, :poll, "2026-06-24T14:00:00Z")
      assert ResourceStore.processed?(key, "2026-06-24T14:00:00Z")
      refute ResourceStore.processed?(key, "2026-06-24T12:00:00Z")
    end
  end

  describe "a comment whose delivery was lost" do
    # Acceptance criterion 4. Nothing marked this comment, so nothing suppresses
    # it. This is the case a blanket skip-when-webhook-backed would drop on the
    # floor, and the 9% measured loss rate is why it cannot be dropped.
    test "is recovered by the next sweep" do
      :ok = Exchange.subscribe(@topic)

      {_calls, result} = sweep([comment(9002, "the 502'd one")])

      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9002}} = await_event(@topic)
    end

    # The hazard a timestamp watermark would have: comment 9004 is delivered and
    # marks the newest position, while the older 9003 was lost. "Anything newer
    # than the last thing I processed" would silently discard 9003 forever.
    # Identity suppression cannot make that mistake.
    test "is recovered even when a newer sibling was delivered successfully" do
      :ok = Exchange.subscribe(@topic)

      assert %{status: :published, published: [@topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(9004, "newer, delivered"), repo: @repo)

      assert %{comment: %{"id" => 9004}} = await_event(@topic)

      {_calls, result} =
        sweep([
          comment(9003, "older, lost", "2026-06-24T11:30:00Z"),
          comment(9004, "newer, delivered", "2026-06-24T11:45:00Z")
        ])

      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9003}} = await_event(@topic)
      refute_event(@topic)
    end
  end

  describe "cost" do
    # Acceptance criterion 1. A steady-state cycle over unchanged resources
    # should cost nothing, not merely less: a 304 does not count against
    # GitHub's primary REST limit. The assertion is on the request the poller
    # actually sends, because that is the thing that either is or is not
    # conditional.
    test "an unchanged sweep revalidates with If-None-Match and publishes nothing" do
      :ok = Exchange.subscribe(@topic)

      # First sweep has no validator to send, so it is a full-price read.
      {first_calls, _result} = sweep([comment(9005, "first read")], etag: ~s("v1"))
      assert [request] = first_calls
      refute Map.has_key?(request, :etag)
      assert %{comment: %{"id" => 9005}} = await_event(@topic)

      # Second sweep sends it back and GitHub answers 304 — free.
      {second_calls, result} = sweep(:not_modified)

      assert [%{etag: ~s("v1")}] = Enum.map(second_calls, &Map.take(&1, [:etag]))
      assert {:ok, %{count: 0, errors: []}} = result
      refute_event(@topic)
    end

    # Acceptance criterion 5, at the level that matters operationally: the
    # validator has to come back after the process holding it dies, or the first
    # sweep of every boot is a full-price read of every watched ticket.
    test "the validator survives a restart of the store, and so does the answer", %{store_path: store_path} do
      # Point the store at a real file for this case: with no resolvable state
      # directory it runs in memory, which would make the restart trivially
      # pass nothing rather than prove the checkpoint round-trip.
      restart_store!(store_path)
      :ok = Exchange.subscribe(@topic)

      # A real full-price read is what mints the validator, so the checkpoint
      # holds what the daemon actually had: the list *and* its validator. A case
      # that only checks the validator came back cannot tell a working cache from
      # one that revalidates its way to an empty answer forever.
      {_calls, {:ok, %{count: 1}}} = sweep([comment(9008, "read before the restart")], etag: ~s("survives"))
      assert %{comment: %{"id" => 9008}} = await_event(@topic)

      assert :ok = ResourceStore.flush()
      assert File.exists?(store_path)

      restart_store!(store_path)

      {calls, result} = sweep(:not_modified)

      assert [%{etag: ~s("survives")}] = Enum.map(calls, &Map.take(&1, [:etag]))
      assert {:ok, %{errors: []}} = result

      resource = ResourceStore.key_for_repo(:issue_comments, @repo, "42")

      assert ResourceStore.data(resource) == [comment(9008, "read before the restart")],
             "a validator whose body did not survive can only ever answer 304 and nothing"
    end
  end

  # F1. The validator for the comment *list* is a single endpoint-level
  # validator, so GitHub answering `304` to it suppresses every comment in the
  # list at once and no per-comment reconciliation can see inside that answer.
  # Recording it before publishing the comments it covers therefore had a
  # routine loss, not an exotic one: `ResourceStore` starts before `Publisher`
  # and the poller, so on SIGTERM the poller dies first while the store
  # checkpoints last.
  describe "a comment read but not yet published" do
    test "is published before the endpoint validator is recorded" do
      :ok = Exchange.subscribe(@topic)
      resource = ResourceStore.key_for_repo(:issue_comments, @repo, "42")
      :ok = ResourceStore.subscribe(resource)

      {_calls, {:ok, %{count: 1}}} = sweep([comment(9600, "must be published first")])

      order =
        for _step <- 1..2 do
          receive do
            {:event, %{topic: @topic}} -> :comment_published
            {:github_resource_changed, %{resource_type: :issue_comments}} -> :validator_recorded
          after
            2_000 -> :nothing
          end
        end

      assert order == [:comment_published, :validator_recorded],
             "the crash window between the two must contain no validator: #{inspect(order)}"
    end

    test "is recovered from the store when GitHub answers 304 after a restart", %{store_path: store_path} do
      restart_store!(store_path)
      :ok = Exchange.subscribe(@topic)

      {_calls, {:ok, %{count: 1}}} = sweep([comment(9601, "the one that would get lost")], etag: ~s("v2"))
      assert %{comment: %{"id" => 9601}} = await_event(@topic)

      # The state a cycle that died between the read and the publish leaves
      # behind: the list and its validator are stored, the comment itself is
      # unmarked — `Publisher` marks only *after* a publish — and nobody ever saw
      # it. The replay window goes too, because a restart empties it.
      ResourceStore.forget(ResourceStore.key_for_repo(:issue_comment, @repo, 9601))
      clear_replay_window()

      assert :ok = ResourceStore.flush()
      restart_store!(store_path)

      # GitHub is right to answer 304: the list has not changed since the
      # validator was minted. The store has to be able to answer anyway.
      {calls, result} = sweep(:not_modified, etag: ~s("v2"))

      assert [%{etag: ~s("v2")}] = Enum.map(calls, &Map.take(&1, [:etag]))
      assert {:ok, %{count: 1}} = result

      assert %{comment: %{"id" => 9601}} = await_event(@topic),
             "a 304 must publish what a 200 would have, or the comment is lost for the whole retention window"
    end

    test "an unchanged 304 still publishes nothing once the comment is marked" do
      :ok = Exchange.subscribe(@topic)

      {_calls, {:ok, %{count: 1}}} = sweep([comment(9602, "seen once")], etag: ~s("v3"))
      assert %{comment: %{"id" => 9602}} = await_event(@topic)
      clear_replay_window()

      for _cycle <- 1..3 do
        assert {:ok, %{count: 0}} = elem(sweep(:not_modified, etag: ~s("v3")), 1)
      end

      refute_event(@topic)
    end

    # The other half of the store's validator/body contract, now enforced by the
    # store itself: `etag/1` does not offer a validator the store cannot serve a
    # body for, so the sweep never spends the empty `304` at all. The comment is
    # recovered by the *first* read rather than the second — one request instead
    # of two.
    test "a durable validator with no body is never sent, and the read recovers the comment", %{store_path: store_path} do
      restart_store!(store_path)
      :ok = Exchange.subscribe(@topic)

      resource = ResourceStore.key_for_repo(:issue_comments, @repo, "42")
      ResourceStore.put_etag(resource, ~s("bodyless"))
      assert :ok = ResourceStore.flush()
      restart_store!(store_path)

      assert ResourceStore.change_validator(resource) == ~s("bodyless"),
             "the validator is still recorded; it is simply not offered to a reader of bodies"

      {calls, result} = sweep([comment(9603, "recovered by the unconditional read")])

      assert [request] = calls
      refute Map.has_key?(request, :etag), "a validator with no body behind it must not be spent"
      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9603}} = await_event(@topic)
    end
  end

  describe "a repo with no webhook" do
    # Acceptance criterion 6. Nothing about this path is conditional on webhook
    # transport, which is the point: an unproven repo never had a delivery, so
    # nothing is ever marked, so nothing is ever suppressed. It polls and
    # publishes exactly as it did before this store existed.
    test "publishes everything the sweep reads, exactly as before" do
      :ok = Exchange.subscribe(@topic)

      {_calls, result} =
        sweep([
          comment(9006, "one", "2026-06-24T11:30:00Z"),
          comment(9007, "two", "2026-06-24T11:45:00Z")
        ])

      assert {:ok, %{count: 2}} = result
      assert %{comment: %{"id" => 9006}} = await_event(@topic)
      assert %{comment: %{"id" => 9007}} = await_event(@topic)
    end
  end

  # Review submissions are the last comment kind the poller still re-read at
  # full price every cycle (#2069). The webhook delivers `pull_request_review`
  # free and marks the `:pr_review` resource; the sweep re-read the same list
  # unconditionally. These pin the same reconciliation contract for reviews
  # that the issue-comment tests above pin for comments.
  describe "a review submission the webhook delivered" do
    # Acceptance criterion 3, applied to review submissions: published once by
    # the delivery, not again by the sweep.
    test "is published once by the delivery and not again by the sweep" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")

      review = review(9001, "its-everdred", "CHANGES_REQUESTED", "please rework this section", "2026-06-24T12:00:00Z")

      assert %{status: :published, published: ["ticket.42.pr.review_comment"]} =
               GithubWebhook.handle_delivery("pull_request_review", review_delivery(review), repo: @repo)

      assert %{comment: %{"id" => 9001}} = await_event("ticket.42.pr.review_comment")

      # The sweep reads the very same review list back from GitHub.
      {calls, result} = review_sweep([review])

      assert {:ok, %{count: 0}} = result
      assert length(calls) == 1
      refute_event("ticket.42.pr.review_comment")
    end

    # Acceptance criterion 4, applied to review submissions. Nothing marked the
    # review, so the sweep publishes it — the delivery-loss case a blanket
    # skip-when-webhook-backed would drop.
    test "is recovered by the next sweep when its delivery was lost" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")

      review = review(9002, "its-everdred", "CHANGES_REQUESTED", "the 502'd one", "2026-06-24T12:00:00Z")

      {_calls, result} = review_sweep([review])

      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9002}} = await_event("ticket.42.pr.review_comment")
    end

    # The restart case, applied to reviews. The in-memory replay window empties
    # on restart, and so does the orchestrator's `pr_review_seen_at` watermark —
    # the first sweep after one re-reads the whole review list. The durable
    # `:pr_review` mark is what stops the old CHANGES_REQUESTED from waking the
    # agent again.
    test "stays suppressed across a restart of the replay window" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")

      review = review(9005, "its-everdred", "CHANGES_REQUESTED", "before the restart", "2026-06-24T12:00:00Z")

      assert %{status: :published, published: ["ticket.42.pr.review_comment"]} =
               GithubWebhook.handle_delivery("pull_request_review", review_delivery(review), repo: @repo)

      assert %{comment: %{"id" => 9005}} = await_event("ticket.42.pr.review_comment")
      clear_replay_window()

      {_calls, result} = review_sweep([review])

      assert {:ok, %{count: 0}} = result
      refute_event("ticket.42.pr.review_comment")
    end
  end

  describe "review submission cost" do
    # Acceptance criterion 1, applied to review submissions: an unchanged review
    # list revalidates with If-None-Match and GitHub answers 304 — a request the
    # primary REST limit does not bill. The assertion is on the request the
    # poller actually sends.
    test "an unchanged review list revalidates with If-None-Match and publishes nothing" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")

      review = review(9003, "its-everdred", "CHANGES_REQUESTED", "seen once", "2026-06-24T12:00:00Z")

      # First sweep has no validator to send, so it is a full-price read.
      {first_calls, _result} = review_sweep([review], etag: ~s("rv1"))
      assert [request] = first_calls
      refute Map.has_key?(request, :etag)
      assert %{comment: %{"id" => 9003}} = await_event("ticket.42.pr.review_comment")

      # Second sweep sends it back and GitHub answers 304 — free.
      {second_calls, result} = review_sweep(:not_modified, etag: ~s("rv1"))

      assert [%{etag: ~s("rv1")}] = Enum.map(second_calls, &Map.take(&1, [:etag]))
      assert {:ok, %{count: 0, errors: []}} = result
      refute_event("ticket.42.pr.review_comment")
    end
  end

  # -- helpers ---------------------------------------------------------------

  # Runs one comment-poll cycle against a recording request stub and returns
  # {requests, result}. `open_pull_request: nil` keeps the cycle to the issue
  # comment read so the request count means what it says.
  defp sweep(response, opts \\ []) do
    {:ok, recorder} = Agent.start_link(fn -> [] end)
    etag = Keyword.get(opts, :etag, ~s("v1"))

    request_fun = fn request ->
      Agent.update(recorder, &(&1 ++ [request]))

      case response do
        :not_modified ->
          {:ok, %{status: 304, headers: [{"etag", etag}]}}

        comments when is_list(comments) ->
          {:ok, %{status: 200, body: comments, headers: [{"etag", etag}]}}
      end
    end

    result =
      GithubCommentsPoller.poll(["42"],
        since: "2026-06-24T11:00:00Z",
        repo: @repo,
        request_fun: request_fun,
        comment_batch: %{"42" => %{open_pull_request: nil}}
      )

    calls = Agent.get(recorder, & &1)
    Agent.stop(recorder)

    {calls, result}
  end

  # Runs one review-submission poll cycle against a recording request stub and
  # returns {requests, result}. The `open_pull_request` batch entry points the
  # cycle at PR 77's review list; issue/PR conversation comments and the
  # GraphQL thread read answer from the batch so the only request under test is
  # `/pulls/77/reviews`.
  defp review_sweep(response, opts \\ []) do
    {:ok, recorder} = Agent.start_link(fn -> [] end)
    etag = Keyword.get(opts, :etag, ~s("rv1"))

    request_fun = fn request ->
      Agent.update(recorder, &(&1 ++ [request]))

      case response do
        :not_modified ->
          {:ok, %{status: 304, headers: [{"etag", etag}]}}

        reviews when is_list(reviews) ->
          {:ok, %{status: 200, body: reviews, headers: [{"etag", etag}]}}
      end
    end

    result =
      GithubCommentsPoller.poll(["42"],
        since: "2026-06-24T11:00:00Z",
        repo: @repo,
        request_fun: request_fun,
        comment_batch: %{
          "42" => %{
            open_pull_request: %{"number" => 77},
            issue_comments: [],
            pr_issue_comments: [],
            review_thread_comments: []
          }
        }
      )

    calls = Agent.get(recorder, & &1)
    Agent.stop(recorder)

    {calls, result}
  end

  defp delivery(id, body) do
    %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "issue" => %{"number" => 42},
      "comment" => comment(id, body),
      "sender" => %{"login" => "its-everdred"}
    }
  end

  defp comment(id, body, updated_at \\ "2026-06-24T12:00:00Z") do
    %{
      "id" => id,
      "body" => body,
      "created_at" => updated_at,
      "updated_at" => updated_at,
      "html_url" => "https://example.test/comments/#{id}",
      "user" => %{"login" => "its-everdred"}
    }
  end

  # A review submission as `GET /pulls/N/reviews` reports it — `state` in upper
  # case, `submitted_at` as the mutation marker the `:pr_review` resource
  # version is keyed on.
  defp review(id, login, state, body, submitted_at) do
    %{
      "id" => id,
      "state" => state,
      "body" => body,
      "submitted_at" => submitted_at,
      "user" => %{"login" => login}
    }
  end

  defp review_delivery(review) do
    %{
      "action" => "submitted",
      "repository" => %{"full_name" => @repo},
      "review" => review,
      "pull_request" => %{"number" => 77, "head" => %{"ref" => "aiur/42-some-slug", "sha" => "deadbeef"}},
      "sender" => %{"login" => "its-everdred"}
    }
  end

  # Empties only the volatile replay window, leaving the durable resource marks
  # in place — the state a daemon restart actually produces.
  defp clear_replay_window do
    case :ets.whereis(Aiur.Events.Publisher.Dedup) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end
  end

  defp restart_store!(path) do
    pid = Process.whereis(ResourceStore)
    ref = Process.monitor(pid)
    Supervisor.terminate_child(Aiur.Supervisor, ResourceStore)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> flunk("ResourceStore did not stop")
    end

    Application.put_env(:aiur, :github_resource_store_path, path)
    {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
    :ok
  end

  defp await_event(topic) do
    receive do
      {:event, %{topic: ^topic} = event} -> event
    after
      1_000 -> flunk("no event published on #{topic}")
    end
  end

  defp refute_event(topic) do
    receive do
      {:event, %{topic: ^topic} = event} -> flunk("unexpected second publish on #{topic}: #{inspect(event)}")
    after
      200 -> :ok
    end
  end
end
