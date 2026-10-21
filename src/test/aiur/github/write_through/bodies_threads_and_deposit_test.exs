defmodule Aiur.GitHub.WriteThrough.BodiesThreadsAndDepositTest do
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

  alias Aiur.Events.GithubWebhook
  alias Aiur.GitHub.DependenciesApi
  alias Aiur.GitHub.IssueState
  alias Aiur.GitHub.PollSnapshots
  alias Aiur.GitHub.PullRequests
  alias Aiur.GitHub.ResourceStore
  alias Aiur.GitHub.ReviewThreads.Reply
  alias Aiur.GitHub.ReviewThreads.Resolution
  alias Aiur.GitHub.WriteThrough

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
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    {:ok, store_path: Path.join(dir, "github_resources.json")}
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
