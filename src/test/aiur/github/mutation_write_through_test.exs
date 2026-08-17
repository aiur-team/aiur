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

  alias Aiur.Events.{Exchange, GithubWebhook}
  alias Aiur.GitHub.{Comments, DependenciesApi, IssueState, PullRequests, ResourceStore}
  alias Aiur.GitHub.ReviewThreads.{Reply, Resolution}

  @repo "owner/repo"
  @topic "ticket.42.issue.commented"
  @author "its-everdred"

  # Comment ids live in a band no other suite uses. `Aiur.Events.Publisher`'s
  # replay window is ETS owned by a long-lived process and the shared setup does
  # not empty it, so any case here that publishes a delivery for a comment id
  # another file also uses would silently dedup that file's case instead.

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: @repo)

    dir = Path.join(System.tmp_dir!(), "aiur-write-through-#{System.unique_integer([:positive])}")
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
      :ok = Exchange.subscribe(@topic)

      {_calls, :ok} = post_comment(640_003, "written through first")

      # `:deduped` and not `:filtered` is the assertion that matters: the
      # delivery reached the resource gate and was recognised there, rather than
      # being dropped earlier by the actor or contamination filters.
      assert %{status: :published, published: [], results: [{@topic, :deduped}]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(640_003, "written through first"), repo: @repo)

      refute_event(@topic)
    end

    # The control for the case above. Without a write-through in front of it the
    # identical delivery publishes, so suppression is a property of the deposit
    # and not of anything else in this fixture.
    test "a comment Aiur did not post is still published by its delivery" do
      :ok = Exchange.subscribe(@topic)

      assert %{status: :published, published: [@topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(640_004, "a human wrote this"), repo: @repo)

      assert %{comment: %{"id" => 640_004}} = await_event(@topic)
    end

    # The other half of the contract. Suppression is keyed on identity *plus*
    # version, so editing the comment Aiur posted — a normal way to correct an
    # agent — still wakes it. Identity alone would swallow the correction for
    # the store's whole 72-hour retention.
    test "an edit of that same comment is still published" do
      :ok = Exchange.subscribe(@topic)

      {_calls, :ok} = post_comment(640_005, "the original instruction")

      edited =
        640_005
        |> delivery("the corrected instruction")
        |> Map.put("action", "edited")
        |> put_in(["comment", "updated_at"], "2026-08-17T14:00:00Z")

      assert %{status: :published, published: [@topic]} =
               GithubWebhook.handle_delivery("issue_comment", edited, repo: @repo)

      assert %{comment: %{"body" => "the corrected instruction"}} = await_event(@topic)
    end

    # Criterion 4. A cache that records writes that did not happen is worse than
    # no cache: it would suppress the delivery for a comment that never existed.
    test "a failed mutation deposits nothing" do
      {_calls, result} =
        record(fn _request -> {:ok, %{status: 422, body: %{"message" => "Validation Failed"}}} end, fn request_fun ->
          Comments.create_comment("42", "never posted", request_fun: request_fun)
        end)

      assert {:error, _reason} = result
      assert ResourceStore.fetch(comment_key(640_006)) == :miss
    end

    test "a transport failure deposits nothing" do
      {_calls, result} =
        record(fn _request -> {:error, :timeout} end, fn request_fun ->
          Comments.create_comment("42", "never posted", request_fun: request_fun)
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
      seed_issue(42, ["agent:todo"])
      key = issue_key(42)
      view = start_view(key)

      {calls, result} =
        record(fn _request -> {:ok, %{status: 200, body: labels(["agent:todo", "agent:in-progress"])}} end, fn fun ->
          IssueState.add_label("42", "agent:in-progress", request_fun: fun)
        end)

      assert result == :ok
      assert_receive {:rendered, %{"labels" => rendered}}, 2_000
      assert Enum.map(rendered, & &1["name"]) == ["agent:todo", "agent:in-progress"]
      assert length(calls.()) == 1

      Process.exit(view, :kill)
    end

    test "deposits the whole label set the endpoint returns" do
      {_calls, :ok} =
        record(fn _request -> {:ok, %{status: 200, body: labels(["agent:todo", "priority:1"])}} end, fn fun ->
          IssueState.add_label("42", "priority:1", request_fun: fun)
        end)

      assert {:ok, %{data: deposited}} = ResourceStore.fetch(ResourceStore.key(:issue_labels, "owner", "repo", 42))
      assert Enum.map(deposited, & &1["name"]) == ["agent:todo", "priority:1"]
    end

    # A removal answers with the labels that survived it, which is the state
    # worth holding — a delta would leave the store unable to answer at all.
    test "removing a label deposits the surviving set" do
      seed_issue(42, ["agent:todo", "agent:paused"])

      {_calls, :ok} =
        record(fn _request -> {:ok, %{status: 200, body: labels(["agent:todo"])}} end, fn fun ->
          IssueState.remove_label("42", "agent:paused", request_fun: fun)
        end)

      assert %{"labels" => [%{"name" => "agent:todo"}]} = ResourceStore.data(issue_key(42))
    end

    test "a failed label write deposits nothing" do
      seed_issue(42, ["agent:todo"])

      {_calls, result} =
        record(fn _request -> {:ok, %{status: 403, body: %{"message" => "Resource not accessible"}}} end, fn fun ->
          IssueState.add_label("42", "agent:in-progress", request_fun: fun)
        end)

      assert {:error, _reason} = result
      assert %{"labels" => [%{"name" => "agent:todo"}]} = ResourceStore.data(issue_key(42))
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
      :ok = Exchange.subscribe(@topic)
      :ok = Exchange.subscribe("ticket.42.issue.label.added.agent.in-progress")
      seed_issue(42, ["agent:todo"])

      {_calls, :ok} =
        record(fn _request -> {:ok, %{status: 200, body: labels(["agent:todo", "agent:in-progress"])}} end, fn fun ->
          IssueState.add_label("42", "agent:in-progress", request_fun: fun)
        end)

      assert %{status: :reconciled, hint: %{kind: :issue_state, action: "labeled"}} =
               GithubWebhook.handle_delivery("issues", labelled_delivery("agent:in-progress"), repo: @repo)

      refute_event(@topic)
      refute_event("ticket.42.issue.label.added.agent.in-progress")
    end

    # A label response cannot name the issue's new `updated_at`, so the deposit
    # claims no version. Claiming the old one would let this body outrank a
    # writer that genuinely knows, and inventing one would suppress a change
    # nothing has handled.
    test "claims no version it cannot vouch for" do
      seed_issue(42, ["agent:todo"])

      {_calls, :ok} =
        record(fn _request -> {:ok, %{status: 200, body: labels(["agent:todo", "agent:watch"])}} end, fn fun ->
          IssueState.add_label("42", "agent:watch", request_fun: fun)
        end)

      assert {:ok, %{version: nil}} = ResourceStore.fetch(issue_key(42))
      refute ResourceStore.processed?(issue_key(42), nil)
    end
  end

  describe "a body Aiur edits" do
    # `PATCH /issues/:number` answers with the whole issue at its new
    # `updated_at`, so closing a ticket both deposits the closed state and marks
    # that version handled.
    test "closing a ticket deposits the closed issue at its new version" do
      {_calls, :ok} =
        record(&close_issue_response/1, fn fun ->
          IssueState.maybe_close_issue(fun, "token", "https://api.github.com/repos/owner/repo/issues/42", "done")
        end)

      assert {:ok, %{data: %{"state" => "closed"}, version: "2026-08-17T15:00:00Z"}} =
               ResourceStore.fetch(issue_key(42))

      assert ResourceStore.processed?(issue_key(42), "2026-08-17T15:00:00Z")
      refute ResourceStore.processed?(issue_key(42), "2026-08-17T16:00:00Z")
    end

    test "a refused close deposits nothing" do
      {_calls, result} =
        record(fn _request -> {:ok, %{status: 410, body: %{"message" => "Gone"}}} end, fn fun ->
          IssueState.maybe_close_issue(fun, "token", "https://api.github.com/repos/owner/repo/issues/42", "done")
        end)

      assert {:error, _reason} = result
      assert ResourceStore.fetch(issue_key(42)) == :miss
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
      blocker = %{"number" => 41, "title" => "the blocker", "updated_at" => "2026-08-17T15:45:00Z"}

      {_calls, result} =
        record(fn _request -> {:ok, %{status: 200, body: blocker}} end, fn fun ->
          DependenciesApi.add_dependency(42, 900_041, request_fun: fun)
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

    test "resolving a thread deposits its resolution state" do
      {_calls, result} =
        record(&resolve_thread_response/1, fn fun ->
          Resolution.resolve_review_thread_mutation(fun, "token", "PRRT_thread")
        end)

      assert {:ok, _body} = result

      assert %{"isResolved" => true} =
               ResourceStore.data(ResourceStore.key(:pr_review_thread, "owner", "repo", "PRRT_thread"))
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
      assert_receive {:github_resource_changed, %{key: ^key, data?: true, data_version: "v1", source: :mutation}}
      assert ResourceStore.data(key)["body"] == "one"

      ResourceStore.put_resource(key, %{"id" => 640_100, "body" => "one"}, version: "v1")
      refute_receive {:github_resource_changed, %{key: ^key}}, 200

      ResourceStore.put_resource(key, %{"id" => 640_100, "body" => "two"}, version: "v2")
      assert_receive {:github_resource_changed, %{key: ^key, data_version: "v2"}}
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

  defp post_comment(id, body) do
    record(
      fn _request -> {:ok, %{status: 201, body: comment(id, body)}} end,
      fn request_fun -> Comments.create_comment("42", body, request_fun: request_fun) end
    )
  end

  # Runs `fun` against a recording stub and answers `{count_fun, result}`. The
  # count is a function rather than a number so a case can ask again *after* a
  # view has re-rendered and prove the render cost nothing.
  defp record(responder, fun) do
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    request_fun = fn request ->
      Agent.update(recorder, &[request | &1])
      responder.(request)
    end

    result = fun.(request_fun)
    on_exit(fn -> if Process.alive?(recorder), do: Agent.stop(recorder) end)

    {fn -> Agent.get(recorder, &Enum.reverse/1) end, result}
  end

  # A view: it subscribes, and when the store changes it re-renders by reading
  # the store. It never fetches. That is the whole contract this unit buys.
  defp start_view(key) do
    test = self()

    {:ok, pid} =
      Task.start(fn ->
        ResourceStore.subscribe(key)
        send(test, :view_subscribed)

        receive do
          {:github_resource_changed, %{key: ^key}} -> send(test, {:rendered, ResourceStore.data(key)})
        after
          5_000 -> send(test, :view_timed_out)
        end
      end)

    assert_receive :view_subscribed, 2_000
    pid
  end

  defp seed_issue(number, label_names) do
    ResourceStore.put_resource(
      issue_key(number),
      %{"number" => number, "state" => "open", "labels" => labels(label_names)},
      source: :fetch,
      version: "2026-08-17T12:00:00Z"
    )
  end

  defp labels(names), do: Enum.map(names, &%{"name" => &1})

  defp comment_key(id), do: ResourceStore.key(:issue_comment, "owner", "repo", id)
  defp issue_key(number), do: ResourceStore.key(:issue, "owner", "repo", number)

  defp close_issue_response(_request) do
    {:ok,
     %{
       status: 200,
       body: %{"number" => 42, "state" => "closed", "updated_at" => "2026-08-17T15:00:00Z"}
     }}
  end

  defp review_reply_response(%{body: %{"query" => query}}) do
    if String.contains?(query, "addPullRequestReviewThreadReply") do
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "addPullRequestReviewThreadReply" => %{
               "comment" => %{
                 "id" => "PRRC_node",
                 "databaseId" => 880_001,
                 "body" => "addressed",
                 "updatedAt" => "2026-08-17T16:00:00Z",
                 "author" => %{"login" => @author}
               }
             }
           }
         }
       }}
    else
      {:ok, %{status: 200, body: %{"data" => %{"node" => nil}}}}
    end
  end

  defp resolve_thread_response(_request) do
    {:ok,
     %{
       status: 200,
       body: %{"data" => %{"resolveReviewThread" => %{"thread" => %{"id" => "PRRT_thread", "isResolved" => true}}}}
     }}
  end

  defp labelled_delivery(label) do
    %{
      "action" => "labeled",
      "repository" => %{"full_name" => @repo},
      "label" => %{"name" => label},
      "issue" => %{"number" => 42, "updated_at" => "2026-08-17T13:00:00Z"},
      "sender" => %{"login" => @author}
    }
  end

  defp delivery(id, body) do
    %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "issue" => %{"number" => 42},
      "comment" => comment(id, body),
      "sender" => %{"login" => @author}
    }
  end

  defp comment(id, body, updated_at \\ "2026-08-17T12:00:00Z") do
    %{
      "id" => id,
      "body" => body,
      "created_at" => updated_at,
      "updated_at" => updated_at,
      "html_url" => "https://github.com/owner/repo/issues/42#issuecomment-#{id}",
      "user" => %{"login" => @author}
    }
  end

  defp stop_store! do
    pid = Process.whereis(ResourceStore)
    ref = Process.monitor(pid)
    Supervisor.terminate_child(Aiur.Supervisor, ResourceStore)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> flunk("ResourceStore did not stop")
    end
  end

  defp restart_store!(path) do
    stop_store!()
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
      {:event, %{topic: ^topic} = event} -> flunk("unexpected publish on #{topic}: #{inspect(event)}")
    after
      200 -> :ok
    end
  end
end
