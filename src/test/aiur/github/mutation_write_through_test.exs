defmodule Aiur.GitHub.MutationWriteThroughTest do
  @moduledoc """
  Mutation write-through: the state Aiur's own writes already paid for (#2073, U4a).

  When Aiur changes GitHub — an agent posting a comment, the orchestrator
  applying a label, a ticket closed, a review thread replied to — the API
  answers with the new state. Historically that response was discarded and the
  same fact was read back later at full price, which is an entire class of
  fetch spent learning about changes Aiur made itself.

  Two things have to hold at once and they pull in opposite directions:

    * the deposit must reach every subscribed view **without** an extra call and
      **before** any webhook for it could arrive, and
    * the webhook that then does arrive must not wake anybody a second time for
      a change they made themselves — the `bot_account` self-loop, one layer
      down.

  Version-aware suppression is what satisfies both. A deposit records the
  resource's own `updated_at`, so the delivery for *that* version is recognised
  as handled while a later genuine edit, which moves `updated_at`, is not.
  """

  use Aiur.TestSupport
  use Aiur.TestSupport.EventTicket
  import Aiur.TestSupport.MutationFixture

  alias Aiur.Events.{Exchange, GithubWebhook}
  alias Aiur.GitHub.{Comments, DependenciesApi, IssueState, PollSnapshots, PullRequests, ResourceStore, WriteThrough}
  alias Aiur.GitHub.ReviewThreads.{Reply, Resolution}

  @repo "owner/repo"
  @author "its-everdred"

  # Comment ids live in a band no other suite uses. `Aiur.Events.Publisher`'s
  # replay window is ETS owned by a long-lived process and the shared setup does
  # not empty it, so any case here that publishes a delivery for a comment id
  # another file also uses would silently dedup that file's case instead.

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: @repo)

    dir = Aiur.TestSupport.tmp_root!("aiur-write-through")
    File.mkdir_p!(dir)

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)
      Application.delete_env(:aiur, :github_resource_store_path)

      if Process.whereis(ResourceStore) == nil do
        Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
      end

      ResourceStore.reset()
      File.rm_rf(dir)
    end)

    {:ok, store_path: Path.join(dir, "github_resources.json")}
  end

  describe "a comment Aiur posts" do
    # A4a, the call-count half. The mutation's own round trip is the only call
    # anybody makes; the state it returned is already the answer.
    test "deposits the comment it created and makes no second call" do
      {calls, result} = post_comment(640_001, "posted by the agent")

      assert result == :ok
      assert length(calls.()) == 1

      assert {:ok, %{data: %{"id" => 640_001, "body" => "posted by the agent"}, source: :mutation}} =
               ResourceStore.fetch(comment_key(640_001))

      # Reading the deposited state is what a view does, and it costs nothing.
      assert length(calls.()) == 1
    end

    # A4a, the view half. The subscriber re-renders off the deposit, and the
    # assertion that nothing was delivered is the point: the new state is
    # visible strictly before any webhook for it could have arrived.
    test "updates a subscribed view with no additional API call and no webhook" do
      key = comment_key(640_002)
      view = start_view(key)

      {calls, :ok} = post_comment(640_002, "the agent's own update")

      assert_receive {:rendered, %{"body" => "the agent's own update"}}, 2_000
      assert length(calls.()) == 1

      # No delivery has been simulated in this case, and the entry names the
      # writer that produced it — so the render provably came from the mutation
      # rather than from a webhook this fixture never sent.
      assert {:ok, %{source: :mutation}} = ResourceStore.fetch(key)

      Process.exit(view, :kill)
    end

    # A4b. The delivery GitHub sends moments later names the same resource at
    # the same version, so it is recognised as already-processed. Note the
    # author is a human login, not the configured `bot_account`: this asserts
    # the version suppression itself rather than the pre-existing self-loop
    # filter that would otherwise be doing the work.
    test "beats its own webhook, which then causes no second publish" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)

      {_calls, :ok} = post_comment(640_003, "written through first")

      # `:deduped` and not `:filtered` is the assertion that matters: the
      # delivery reached the resource gate and was recognised there, rather than
      # being dropped earlier by the actor or contamination filters.
      assert %{status: :published, published: [], results: [{^topic, :deduped}]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(640_003, "written through first"), repo: @repo)

      refute_event(topic)
    end

    # The control for the case above. Without a write-through in front of it the
    # identical delivery publishes, so suppression is a property of the deposit
    # and not of anything else in this fixture.
    test "a comment Aiur did not post is still published by its delivery" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)

      assert %{status: :published, published: [^topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(640_004, "a human wrote this"), repo: @repo)

      assert %{comment: %{"id" => 640_004}} = await_event(topic)
    end

    # The other half of the contract. Suppression is keyed on identity *plus*
    # version, so editing the comment Aiur posted — a normal way to correct an
    # agent — still wakes it. Identity alone would swallow the correction for
    # the store's whole 72-hour retention.
    test "an edit of that same comment is still published" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)

      {_calls, :ok} = post_comment(640_005, "the original instruction")

      edited =
        640_005
        |> delivery("the corrected instruction")
        |> Map.put("action", "edited")
        |> put_in(["comment", "updated_at"], "2026-08-17T14:00:00Z")

      assert %{status: :published, published: [^topic]} =
               GithubWebhook.handle_delivery("issue_comment", edited, repo: @repo)

      assert %{comment: %{"body" => "the corrected instruction"}} = await_event(topic)
    end

    # Criterion 4. A cache that records writes that did not happen is worse than
    # no cache: it would suppress the delivery for a comment that never existed.
    test "a failed mutation deposits nothing" do
      ticket = ticket_id()

      {_calls, result} =
        record(fn _request -> {:ok, %{status: 422, body: %{"message" => "Validation Failed"}}} end, fn request_fun ->
          Comments.create_comment(ticket, "never posted", request_fun: request_fun)
        end)

      assert {:error, _reason} = result
      assert ResourceStore.fetch(comment_key(640_006)) == :miss
    end

    test "a transport failure deposits nothing" do
      ticket = ticket_id()

      {_calls, result} =
        record(fn _request -> {:error, :timeout} end, fn request_fun ->
          Comments.create_comment(ticket, "never posted", request_fun: request_fun)
        end)

      assert {:error, _reason} = result
      assert ResourceStore.size() == 0
    end
  end

  describe "a label Aiur applies" do
    # A4a for the label writer. GitHub answers a label write with the issue's
    # complete label array, so the held issue body can be corrected in place and
    # the view re-renders off that — no fetch, and no waiting for the `issues`
    # delivery.
    test "updates a subscribed view of the issue with no additional call" do
      ticket = ticket_id()
      number = ticket_number()
      seed_issue(number, ["agent:todo"])
      key = issue_key(number)
      view = start_view(key)

      {calls, result} =
        record(fn _request -> {:ok, %{status: 200, body: labels(["agent:todo", "agent:in-progress"])}} end, fn fun ->
          IssueState.add_label(ticket, "agent:in-progress", request_fun: fun)
        end)

      assert result == :ok
      assert_receive {:rendered, %{"labels" => rendered}}, 2_000
      assert Enum.map(rendered, & &1["name"]) == ["agent:todo", "agent:in-progress"]
      assert length(calls.()) == 1

      Process.exit(view, :kill)
    end

    # Both label deposits must leave a marker behind.
    # `ResourceStore.regression?/2` decides staleness by comparing an
    # incoming version against the held `data_version`, and its guard clause
    # needs *both* sides to be binaries — so a deposit that writes `nil` there
    # does not merely omit a marker, it makes every later stale delivery for
    # that key compare as "no judgement" and land. This asserts the marker
    # survives on both keys, which is what keeps that guard switched on.
    test "leaves a version behind so the stale-delivery guard keeps working" do
      ticket = ticket_id()
      number = ticket_number()
      seed_issue(number, ["agent:todo"])

      {_calls, :ok} =
        record(fn _request -> {:ok, %{status: 200, body: labels(["agent:todo", "agent:watch"])}} end, fn fun ->
          IssueState.add_label(ticket, "agent:watch", request_fun: fun)
        end)

      assert {:ok, %{version: "2026-08-17T12:00:00Z"}} = ResourceStore.fetch(issue_key(number))

      assert {:ok, %{version: "2026-08-17T12:00:00Z"}} =
               ResourceStore.fetch(ResourceStore.key(:issue_labels, "owner", "repo", number))
    end

    test "deposits the whole label set the endpoint returns" do
      ticket = ticket_id()
      number = ticket_number()

      {_calls, :ok} =
        record(fn _request -> {:ok, %{status: 200, body: labels(["agent:todo", "priority:1"])}} end, fn fun ->
          IssueState.add_label(ticket, "priority:1", request_fun: fun)
        end)

      assert {:ok, %{data: deposited}} = ResourceStore.fetch(ResourceStore.key(:issue_labels, "owner", "repo", number))
      assert Enum.map(deposited, & &1["name"]) == ["agent:todo", "priority:1"]
    end

    # A removal answers with the labels that survived it, which is the state
    # worth holding — a delta would leave the store unable to answer at all.
    test "removing a label deposits the surviving set" do
      ticket = ticket_id()
      number = ticket_number()
      seed_issue(number, ["agent:todo", "agent:paused"])

      {_calls, :ok} =
        record(fn _request -> {:ok, %{status: 200, body: labels(["agent:todo"])}} end, fn fun ->
          IssueState.remove_label(ticket, "agent:paused", request_fun: fun)
        end)

      assert %{"labels" => [%{"name" => "agent:todo"}]} = ResourceStore.data(issue_key(number))
    end

    test "a failed label write deposits nothing" do
      ticket = ticket_id()
      number = ticket_number()
      seed_issue(number, ["agent:todo"])

      {_calls, result} =
        record(fn _request -> {:ok, %{status: 403, body: %{"message" => "Resource not accessible"}}} end, fn fun ->
          IssueState.add_label(ticket, "agent:in-progress", request_fun: fun)
        end)

      assert {:error, _reason} = result
      assert %{"labels" => [%{"name" => "agent:todo"}]} = ResourceStore.data(issue_key(number))
    end

    # A4b for the label path, which reaches it a different way than the comment
    # path does and is the reason this case exists rather than being assumed
    # from the comment one. An `issues` delivery is never published as a ticket
    # event at all: `Normalizer` answers `{:reconcile, ...}`, so the label Aiur
    # applied causes a "go look at the state" hint and no wake. Asserting the
    # status here pins that, so a later change that started publishing `issues`
    # deliveries through `Publisher` — recreating the self-loop for every label
    # the orchestrator writes — fails in this file instead of in production.
    test "its own issues delivery is a reconcile hint and wakes nobody" do
      ticket = ticket_id()
      number = ticket_number()
      fixture_topic0 = "ticket.#{ticket}.issue.label.added.agent.in-progress"
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)
      :ok = Exchange.subscribe(fixture_topic0)
      seed_issue(number, ["agent:todo"])

      {_calls, :ok} =
        record(fn _request -> {:ok, %{status: 200, body: labels(["agent:todo", "agent:in-progress"])}} end, fn fun ->
          IssueState.add_label(ticket, "agent:in-progress", request_fun: fun)
        end)

      assert %{status: :reconciled, hint: %{kind: :issue_state, action: "labeled"}} =
               GithubWebhook.handle_delivery("issues", labelled_delivery("agent:in-progress"), repo: @repo)

      refute_event(topic)
      refute_event(fixture_topic0)
    end

    # The lost update, pinned. `Aiur.Events.GithubWebhook.Deposit` writes the
    # whole `:issue` body on every `issues` and `issue_comment` delivery, so the
    # racing writer here is the live one, not a hypothetical.
    #
    # The marker is monotonic and the sampler asserts the held body never goes
    # backwards, because that is the failure with teeth: `"state"` rolls back
    # with everything else, so a reader is served `open` for a ticket Aiur has
    # closed. Counting the final generation as well catches a merge that drops
    # the last writes without ever visibly reversing.
    test "concurrent label merges never roll the held issue body backwards" do
      key = issue_key(77)
      generations = 150

      ResourceStore.put_resource(key, issue_at(0), source: :webhook, version: version_at(0))

      # The delivery writer is the observer, because it is the writer that gets
      # lost: it reads back immediately after depositing generation N, and a
      # merge that clobbers it with the snapshot it read earlier shows up as a
      # generation below N. Watching from the merge side cannot see this — a
      # merge always writes back what it just read, so its own view rises
      # monotonically even while it is destroying someone else's write. A
      # separate polling process would also see it, but only by spinning hot
      # enough to perturb the timing of every other test in the run.
      deliveries =
        Task.async(fn ->
          Enum.map(1..generations, fn generation ->
            ResourceStore.put_resource(key, issue_at(generation),
              source: :webhook,
              version: version_at(generation)
            )

            case ResourceStore.data(key) do
              %{"generation" => held} when is_integer(held) and held < generation -> {generation, held}
              _other -> nil
            end
          end)
        end)

      merges =
        Task.async(fn ->
          Enum.each(1..generations, fn n ->
            WriteThrough.issue_labels(77, labels(["agent:todo", "merge:#{n}"]))
          end)
        end)

      regressions = deliveries |> Task.await(60_000) |> Enum.reject(&is_nil/1)
      Task.await(merges, 60_000)

      # No delivery was ever overwritten by an older snapshot of the same issue.
      assert regressions == [],
             "a merge rolled the held issue body back {wrote, found}: #{inspect(Enum.take(regressions, 5))}"

      held = ResourceStore.data(key)

      # The last delivery survived the last merge, rather than being overwritten
      # by a snapshot the merge had read before it.
      assert held["generation"] == generations

      # And the merge still did its job: the label set the mutation returned is
      # the one on the body, so A4a holds under contention too.
      assert Enum.map(held["labels"], & &1["name"]) == ["agent:todo", "merge:#{generations}"]

      # The marker moved with the body. A version-less merge would leave this
      # `nil`, which is precisely the field `ResourceStore.regression?/2`
      # consults — so losing it switches off the stale-delivery guard.
      assert {:ok, %{version: version}} = ResourceStore.fetch(key)
      assert version == version_at(generations)
    end

    # The marker the merge carries is the snapshot's, never a newer one it made
    # up: a label response cannot name the issue's new `updated_at`. Under-
    # claiming is the safe direction — it refuses only what is strictly older
    # than the snapshot these labels were applied to — and it must not be
    # confused with marking the resource *processed*, which needs a version the
    # writer genuinely vouches for and is still refused here.
    test "claims the snapshot's version and never marks it processed" do
      ticket = ticket_id()
      number = ticket_number()
      seed_issue(number, ["agent:todo"])

      {_calls, :ok} =
        record(fn _request -> {:ok, %{status: 200, body: labels(["agent:todo", "agent:watch"])}} end, fn fun ->
          IssueState.add_label(ticket, "agent:watch", request_fun: fun)
        end)

      assert {:ok, %{version: "2026-08-17T12:00:00Z"}} = ResourceStore.fetch(issue_key(number))

      # A label write is not a wake-suppressing event for the issue.
      refute ResourceStore.processed?(issue_key(number), "2026-08-17T12:00:00Z")
      refute ResourceStore.processed?(issue_key(number), nil)
    end
  end

  describe "a body Aiur edits" do
    # `PATCH /issues/:number` answers with the whole issue at its new
    # `updated_at`, so closing a ticket both deposits the closed state and marks
    # that version handled.
    test "closing a ticket deposits the closed issue at its new version" do
      ticket = ticket_id()
      number = ticket_number()
      fixture_value0 = "https://api.github.com/repos/owner/repo/issues/#{ticket}"

      {_calls, :ok} =
        record(&close_issue_response/1, fn fun ->
          IssueState.maybe_close_issue(fun, "token", fixture_value0, "done")
        end)

      assert {:ok, %{data: %{"state" => "closed"}, version: "2026-08-17T15:00:00Z"}} =
               ResourceStore.fetch(issue_key(number))

      assert ResourceStore.processed?(issue_key(number), "2026-08-17T15:00:00Z")
      refute ResourceStore.processed?(issue_key(number), "2026-08-17T16:00:00Z")
    end

    test "a refused close deposits nothing" do
      ticket = ticket_id()
      number = ticket_number()
      fixture_value0 = "https://api.github.com/repos/owner/repo/issues/#{ticket}"

      {_calls, result} =
        record(fn _request -> {:ok, %{status: 410, body: %{"message" => "Gone"}}} end, fn fun ->
          IssueState.maybe_close_issue(fun, "token", fixture_value0, "done")
        end)

      assert {:error, _reason} = result
      assert ResourceStore.fetch(issue_key(number)) == :miss
    end

    test "a repaired pull request base deposits the pull request" do
      pull_request = %{
        "number" => 77,
        "updated_at" => "2026-08-17T15:30:00Z",
        "base" => %{"ref" => "main"},
        "head" => %{"sha" => "abc123"}
      }

      {_calls, result} =
        record(fn _request -> {:ok, %{status: 200, body: pull_request}} end, fn fun ->
          PullRequests.ensure_base_branch(%{"number" => 77, "base" => %{"ref" => "stale"}}, "main",
            request_fun: fun,
            before_base_repair_fun: fn -> :ok end
          )
        end)

      assert {:ok, {:repaired, "abc123"}} = result

      assert {:ok, %{data: %{"number" => 77}, version: "2026-08-17T15:30:00Z"}} =
               ResourceStore.fetch(ResourceStore.key(:pull_request, "owner", "repo", 77))
    end

    test "a declared dependency deposits the blocking issue" do
      number = ticket_number()
      blocker = %{"number" => 41, "title" => "the blocker", "updated_at" => "2026-08-17T15:45:00Z"}

      {_calls, result} =
        record(fn _request -> {:ok, %{status: 200, body: blocker}} end, fn fun ->
          DependenciesApi.add_dependency(number, 900_041, request_fun: fun)
        end)

      assert {:ok, ^blocker} = result
      assert %{"title" => "the blocker"} = ResourceStore.data(issue_key(41))
    end
  end

  describe "a review thread Aiur writes to" do
    # The reply mutation selects `databaseId`, which is the id the
    # `pull_request_review_comment` delivery carries. That shared identity is
    # what lets the deposit suppress the delivery for Aiur's own reply.
    test "a reply deposits the comment under the id its delivery will use" do
      {_calls, result} =
        record(&review_reply_response/1, fn fun ->
          Reply.reply_to_review_thread("PRRT_thread", "addressed", request_fun: fun, attempts: 1, sleep_fun: fn _ -> :ok end)
        end)

      # Verification reads a thread this stub does not serve, so the reply
      # reports unverified — deliberately: the deposit is made from the mutation
      # response, before and independently of the verification round trip.
      assert {:error, {:review_thread_reply_not_verified, _detail}} = result

      key = ResourceStore.key(:pr_review_comment, "owner", "repo", 880_001)
      assert {:ok, %{data: %{"body" => "addressed"}, version: "2026-08-17T16:00:00Z"}} = ResourceStore.fetch(key)
      assert ResourceStore.processed?(key, "2026-08-17T16:00:00Z")
    end

    # The mutation answers in GraphQL's shape and every other producer of this
    # resource type files the poller shape. Depositing the response raw would
    # put a body under this key whose own `"id"` is the node id rather than the
    # id it is keyed by, with no author, no timestamps and no `html_url` — a
    # truncated resource a reader cannot tell apart from a whole one.
    test "a reply is deposited in the shape every other producer of this type files" do
      {_calls, _result} =
        record(&review_reply_response/1, fn fun ->
          Reply.reply_to_review_thread("PRRT_thread", "addressed", request_fun: fun, attempts: 1, sleep_fun: fn _ -> :ok end)
        end)

      deposited = ResourceStore.data(ResourceStore.key(:pr_review_comment, "owner", "repo", 880_001))

      assert deposited["id"] == 880_001
      assert get_in(deposited, ["user", "login"]) == @author
      assert deposited["updated_at"] == "2026-08-17T16:00:00Z"
      assert deposited["html_url"] == "https://github.com/owner/repo/pull/7#discussion_r880001"
    end

    test "a compensating unresolve prevents a delayed resolved delivery from making the aggregate delivery-fresh" do
      assert :ok =
               PollSnapshots.put_review_threads(@repo, 7, [
                 %{"id" => "PRRT_thread", "isResolved" => false, "comments" => %{"nodes" => []}}
               ])

      {_calls, result} =
        record(&resolve_thread_response/1, fn fun ->
          Resolution.resolve_review_thread_mutation(fun, "token", "PRRT_thread")
        end)

      assert {:ok, _body} = result

      assert %{"isResolved" => true} =
               ResourceStore.data(ResourceStore.key(:pr_review_thread, "owner", "repo", "PRRT_thread"))

      assert :miss = PollSnapshots.review_threads(@repo, 7)

      assert {:ok, %{source: :mutation, data: %{"threads" => [%{"id" => "PRRT_thread", "isResolved" => true}]}}} =
               ResourceStore.fetch(PollSnapshots.review_threads_key(@repo, 7))

      # GitHub's compensating unresolve response carries no marker that can
      # order it against the original resolve delivery. It still updates the
      # individual thread, but deliberately drops the complete aggregate.
      WriteThrough.review_thread(%{
        "id" => "PRRT_thread",
        "isResolved" => false,
        "pullRequest" => %{"number" => 7}
      })

      assert %{"isResolved" => false} =
               ResourceStore.data(ResourceStore.key(:pr_review_thread, "owner", "repo", "PRRT_thread"))

      assert :miss = PollSnapshots.review_threads(@repo, 7)

      # The old resolved delivery must not recreate a complete aggregate from
      # which a reader could be served. A subsequent poll is the authority.
      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("pull_request_review_thread", resolved_thread_delivery(), repo: @repo)

      assert :miss = PollSnapshots.review_threads(@repo, 7)
    end
  end

  describe "the deposit itself" do
    # A deposit that changes nothing must not wake every subscribed view, or a
    # reconciliation sweep re-depositing unchanged state becomes a broadcast
    # storm that costs more than the reads it saved.
    test "publishes only when the resource actually changed" do
      key = comment_key(640_100)
      :ok = ResourceStore.subscribe(key)

      ResourceStore.put_resource(key, %{"id" => 640_100, "body" => "one"}, version: "v1")

      # The change is a map, not a tuple, and it carries no body: a subscriber is
      # told *that* the resource moved and reads it from the store. Broadcasting
      # the body would make fan-out cost scale with the number of viewers, which
      # is the cost this design exists to remove.
      assert_receive {:github_resource_changed, %{key: ^key, data?: true, data_version: "v1", source: :mutation}}, 1000
      assert ResourceStore.data(key)["body"] == "one"

      ResourceStore.put_resource(key, %{"id" => 640_100, "body" => "one"}, version: "v1")
      refute_receive {:github_resource_changed, %{key: ^key}}, 200

      ResourceStore.put_resource(key, %{"id" => 640_100, "body" => "two"}, version: "v2")
      assert_receive {:github_resource_changed, %{key: ^key, data_version: "v2"}}, 1000
      assert ResourceStore.data(key)["body"] == "two"
    end

    # `:version` is the version some pipe *processed*; `:data_version` is the
    # version of the body held. Merging them would be a suppression bug — a
    # writer depositing newer data would drag an older processed-mark forward
    # onto a version nothing has handled, and that version's event would never
    # be published.
    test "depositing newer data never advances a processed mark on its own" do
      key = comment_key(640_101)

      ResourceStore.mark_processed(key, :webhook, "v1")
      ResourceStore.put_resource(key, %{"id" => 640_101, "body" => "edited"}, version: "v2", processed: false)

      assert ResourceStore.processed?(key, "v1")
      refute ResourceStore.processed?(key, "v2")
      assert {:ok, %{version: "v2"}} = ResourceStore.fetch(key)
    end

    # A7's shape at this level: a restart must not throw away state the daemon
    # already holds, or the first reader after every restart pays full price.
    test "survives a restart of the store", %{store_path: store_path} do
      restart_store!(store_path)

      key = comment_key(640_102)
      ResourceStore.put_resource(key, %{"id" => 640_102, "body" => "durable"}, version: "v1", processed: true)
      assert :ok = ResourceStore.flush()

      restart_store!(store_path)

      assert {:ok, %{data: %{"body" => "durable"}, version: "v1"}} = ResourceStore.fetch(key)
      assert ResourceStore.processed?(key, "v1")
    end

    # R11. The store is a cache; a mutation must not fail because caching its
    # result did.
    test "a mutation still succeeds with the store stopped" do
      stop_store!()

      {_calls, result} = post_comment(640_103, "no store running")

      assert result == :ok
      assert ResourceStore.fetch(comment_key(640_103)) == :miss
    end
  end

  # -- helpers ---------------------------------------------------------------
end
