defmodule Aiur.Events.GithubWebhook.DepositTest do
  @moduledoc """
  Webhook deliveries populate the resource store (R2), not merely fire an event.

  A delivery is the only writer that costs nothing and the only one that arrives
  first, so it is the writer whose absence is most expensive: before this, the
  store held ETags and suppression marks and no bodies at all, which made
  `ResourceStore.fetch/1` a guaranteed miss and every reader that had been
  converted to "read the store" a guaranteed fetch.

  The assertions here are on **call counts** and on stored content, never on
  latency and never on a percentage. Two different counters, deliberately:
  `read_through/1` counts the fetches a consumer would have had to pay for,
  which is what A3 is about; `sweep/1` counts the requests the comment poller
  actually sends through a recording `request_fun`, which is what A6 is about.
  """

  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, GithubCommentsPoller, GithubWebhook, Publisher}
  alias Aiur.GitHub.{ResourceFetch, ResourceStore}
  alias Aiur.Workflow

  @repo "owner/repo"
  @dedup_table Aiur.Events.Publisher.Dedup
  @bot "its-applekid"
  @human "its-everdred"
  @topic "ticket.42.issue.commented"

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: @repo,
      tracker_label_prefix: "aiur",
      tracker_bot_account: @bot
    )

    Publisher.set_tracked_fn(fn _ -> true end)
    clear_dedup()
    ResourceStore.reset()

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)
      Publisher.set_tracked_fn(fn _ -> true end)
      clear_dedup()
      Application.delete_env(:aiur, :github_resource_store_path)

      if is_nil(Process.whereis(ResourceStore)) do
        Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
      end

      ResourceStore.reset()

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end)

    :ok
  end

  describe "A3 — a delivered resource is served from the store with zero upstream calls" do
    test "an issue comment is served with a request count of exactly zero" do
      assert %{status: :published} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9101), repo: @repo)

      key = ResourceStore.key_for_repo(:issue_comment, @repo, 9101)

      # The consumer: read the store, and only pay for a fetch on a miss. The
      # count is the whole assertion — zero, not "fewer".
      {calls, body} = read_through(key)

      assert calls == 0
      assert %{"id" => 9101, "body" => "review this"} = body
    end

    test "the issue the comment hangs off is served with a request count of exactly zero" do
      assert %{status: :published} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9102), repo: @repo)

      {calls, issue} = read_through(ResourceStore.key_for_repo(:issue, @repo, 42))

      assert calls == 0
      assert %{"number" => 42} = issue
    end

    # Non-vacuousness, asserted rather than claimed: the same consumer against a
    # resource no delivery ever arrived for pays for exactly one read. If the
    # deposit stopped happening, the zero-call assertions above would read one
    # here instead, which is the shape of the failure they exist to catch.
    test "a resource with no delivery costs the consumer one call" do
      {calls, body} = read_through(ResourceStore.key_for_repo(:issue_comment, @repo, 9103))

      assert calls == 1
      assert body == :fetched_from_github
    end
  end

  # A deposit nobody can address is a write to nowhere: it costs bytes against
  # the size cap and the entry ceiling, a checkpoint every 30 seconds and a
  # publish on every arrival, and returns nothing. That is not hypothetical.
  # `:pull_request` is deposited keyed by **pull request number**, while the
  # only pull-request consumer reads `:branch_pull_request` keyed by **ticket
  # number** — two pipes keyed so they can never meet (#2126).
  #
  # Nothing caught that, because nothing asserted the two halves address the
  # same entry. This table does, in both directions:
  #
  #   * every type a delivery actually deposits must appear here, so a new type
  #     cannot be added and quietly skipped;
  #   * every type here must declare how it is reached, and one declared
  #     unreachable must *stay* unreachable until somebody reclassifies it.
  #
  # A table that silently ignored a type it did not recognise would be the same
  # absence-of-evidence shape as the guards this file exists to replace.
  #
  #   `{:read_by, who, keys}`  — a consumer addresses exactly these keys.
  #   `{:signal_only, why}`    — no key-addressed reader; consumed as a change
  #                              signal by type, so the key still has to be one
  #                              the store recognises.
  #   `{:unreachable, why}`    — nothing consumes it at all.
  #
  # Each key is built from the *resource's own* identifiers — issue 42, comment
  # 9401, review 9403 — the way the consumer derives them, and never from the id
  # the deposit happened to choose. Feeding the deposited id back into the
  # consumer's key function would make the two agree by construction and would
  # only prove that both call `key/4`.
  defp reachability,
    do: %{
      issue: {:read_by, "Aiur.GitHub.Issues.fetch_issue_raw_conditional/2 (issues.ex:179)", [ResourceStore.key(:issue, "owner", "repo", 42)]},
      issue_comment: {:read_by, "Aiur.Events.GithubCommentsPoller suppression marks (github_comments_poller.ex:602)", [ResourceStore.key_for_repo(:issue_comment, @repo, 9401)]},
      pr_review: {:read_by, "Aiur.Events.GithubCommentsPoller suppression marks (github_comments_poller.ex:587)", [ResourceStore.key_for_repo(:pr_review, @repo, 9403)]},
      pr_review_comment: {:read_by, "Aiur.Events.GithubCommentsPoller suppression marks (github_comments_poller.ex:650)", [ResourceStore.key_for_repo(:pr_review_comment, @repo, 9402)]},
      issue_labels:
        {:signal_only,
         "retires the agent `gh` wrapper's cache through AgentCacheBridge's @invalidating_types; " <>
           "no module builds an :issue_labels key to read one"},
      pull_request:
        {:signal_only,
         "retires the agent cache by type, but no reader addresses it: the only pull-request " <>
           "consumer reads :branch_pull_request keyed by ticket number (#2126)"},
      check_run:
        {:unreachable,
         "deliberately excluded from AgentCacheBridge — a CI verdict is never served from a cache — " <>
           "and no module reads it, so this deposit currently buys nothing (#2126)"}
    }

  describe "every deposit is addressable by whoever wants it" do
    test "the table covers exactly the types a delivery deposits" do
      assert deposited_types() == reachability() |> Map.keys() |> MapSet.new(),
             "a deposited type missing from reachability/0 is an unreviewed write, and a table entry " <>
               "for a type nothing deposits any more is a claim about code that is gone"
    end

    test "a consumer addresses exactly the keys the deposit wrote" do
      deposited = deposited_keys_by_type()

      checked =
        for {type, {:read_by, who, consumer_keys}} <- reachability() do
          assert Map.get(deposited, type) == MapSet.new(consumer_keys),
                 "#{type} is deposited as #{inspect(Map.get(deposited, type))} but #{who} addresses " <>
                   "#{inspect(MapSet.new(consumer_keys))}; the two pipes can never meet"

          type
        end

      # Without this the comprehension could match nothing at all and still
      # pass, which is the precise vacuity this file is being hardened against.
      assert MapSet.new(checked) == read_by_types(),
             "the key-agreement assertion did not run for every :read_by type"
    end

    # The other direction, and the one that would have caught `:pull_request`:
    # a type declared unreachable must have no reader, so the day somebody wires
    # one up this fails and forces the declaration to be corrected rather than
    # left describing the old world.
    test "a type declared unreachable still has no reader" do
      for {type, {kind, why}} <- reachability(), kind in [:signal_only, :unreachable] do
        assert reader_sites(type) == [],
               "#{type} is declared unreachable (#{why}) but #{inspect(reader_sites(type))} now " <>
                 "builds a key for it; reclassify it as :read_by and assert the keys agree"
      end
    end
  end

  describe "delivery types that deposit bodies" do
    test "issue_comment deposits the comment in the poller's shape" do
      GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9201), repo: @repo)

      assert {:ok, %{data: data, source: :webhook, version: "2026-06-24T12:00:00Z"}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:issue_comment, @repo, 9201))

      # The poller's projection, key for key: a consumer must not be able to
      # tell a delivered comment from a polled one.
      assert Map.keys(data) |> Enum.sort() ==
               ["body", "created_at", "html_url", "id", "updated_at", "user"]

      assert data["user"] == %{"login" => @human}
    end

    test "issue_comment deposits the issue and its label set" do
      GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9202), repo: @repo)

      assert {:ok, %{data: %{"number" => 42}}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue, @repo, 42))

      assert {:ok, %{data: [%{"name" => "agent:in-progress"}]}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:issue_labels, @repo, 42))
    end

    test "pull_request_review_comment deposits the comment and the pull request" do
      GithubWebhook.handle_delivery("pull_request_review_comment", review_comment_delivery(9203), repo: @repo)

      assert {:ok, %{data: %{"id" => 9203}, source: :webhook}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:pr_review_comment, @repo, 9203))

      assert {:ok, %{data: %{"number" => 77}}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:pull_request, @repo, 77))
    end

    test "pull_request_review deposits the review with the poller's state casing" do
      GithubWebhook.handle_delivery("pull_request_review", review_delivery(9204), repo: @repo)

      assert {:ok, %{data: %{"state" => "CHANGES_REQUESTED"}, version: "2026-06-24T12:30:00Z"}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:pr_review, @repo, 9204))
    end

    test "pull_request deposits the pull request even when the event only reconciles" do
      # `synchronize` normalizes to a CI reconcile and publishes nothing, so a
      # deposit driven off the publish outcome would miss it entirely.
      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery(
                 "pull_request",
                 %{pull_request_delivery() | "action" => "synchronize"},
                 repo: @repo,
                 reconcile_fun: fn _hint -> :ok end
               )

      assert {:ok, %{data: %{"number" => 77}, source: :webhook}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:pull_request, @repo, 77))
    end

    test "issues deposits the issue and label set even though the event only reconciles" do
      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", issues_delivery("labeled"), repo: @repo, reconcile_fun: fn _ -> :ok end)

      assert {:ok, %{data: %{"number" => 42}}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue, @repo, 42))
      assert {:ok, %{data: [_label]}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_labels, @repo, 42))
    end

    test "check_run deposits the run under its own id" do
      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("check_run", check_run_delivery(5501), repo: @repo, reconcile_fun: fn _ -> :ok end)

      assert {:ok, %{data: %{"id" => 5501, "conclusion" => "success"}, version: "2026-06-24T13:00:00Z"}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:check_run, @repo, 5501))
    end

    test ":check_run is a member of the store's closed type set" do
      # An unlisted type is refused at the key and would vanish at the next
      # restart, so membership is the deposit's precondition, not a detail.
      assert :check_run in ResourceStore.resource_types()
      assert ResourceStore.key_for_repo(:check_run, @repo, 5502) != nil
    end

    @tag :tmp_dir
    test "a deposited check run survives a restart of the store", %{tmp_dir: tmp_dir} do
      # The failure the closed set exists to prevent is not a rejected write, it
      # is a body that writes and reads perfectly all day and then vanishes at
      # the next restart with no error. Only a real checkpoint round trip can
      # tell those apart, so this one uses a file.
      path = Path.join(tmp_dir, "github_resources.json")
      restart_store!(path)

      GithubWebhook.handle_delivery("check_run", check_run_delivery(5503), repo: @repo, reconcile_fun: fn _ -> :ok end)
      assert :ok = ResourceStore.flush()

      restart_store!(path)

      assert {:ok, %{data: %{"id" => 5503}, source: :webhook}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:check_run, @repo, 5503))
    end

    test "a delivery for an untracked repository deposits nothing" do
      GithubWebhook.handle_delivery(
        "issue_comment",
        %{issue_comment_delivery(9205) | "repository" => %{"full_name" => "someone/else"}},
        repo: @repo
      )

      assert :miss = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_comment, "someone/else", 9205))
      assert :miss = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_comment, @repo, 9205))
    end

    test "a deleted comment drops the held body rather than serving a stale one" do
      GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9206), repo: @repo)
      key = ResourceStore.key_for_repo(:issue_comment, @repo, 9206)
      assert {:ok, _entry} = ResourceStore.fetch(key)

      GithubWebhook.handle_delivery(
        "issue_comment",
        %{issue_comment_delivery(9206) | "action" => "deleted"},
        repo: @repo
      )

      assert :miss = ResourceStore.fetch(key)
    end

    test "deleting a comment keeps the issue the same delivery carried" do
      # The action belongs to the comment. Letting it reach the issue would throw
      # away a cached issue body using a delivery that is holding a current one.
      GithubWebhook.handle_delivery(
        "issue_comment",
        %{issue_comment_delivery(9207) | "action" => "deleted"},
        repo: @repo
      )

      assert :miss = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_comment, @repo, 9207))
      assert {:ok, %{data: %{"number" => 42}}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue, @repo, 42))
      assert {:ok, %{data: [_label]}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_labels, @repo, 42))
    end

    test "a deleted issue takes its label set with it" do
      GithubWebhook.handle_delivery("issues", issues_delivery("labeled"), repo: @repo, reconcile_fun: fn _ -> :ok end)
      assert {:ok, _entry} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_labels, @repo, 42))

      GithubWebhook.handle_delivery("issues", issues_delivery("deleted"), repo: @repo, reconcile_fun: fn _ -> :ok end)

      # An issue body nothing holds beside a label set something does would be an
      # entry that contradicts itself.
      assert :miss = ResourceStore.fetch(ResourceStore.key_for_repo(:issue, @repo, 42))
      assert :miss = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_labels, @repo, 42))
    end

    test "a dismissed review is deposited without claiming an unchanged version" do
      GithubWebhook.handle_delivery("pull_request_review", review_delivery(9208), repo: @repo)

      dismissed =
        9208
        |> review_delivery()
        |> Map.put("action", "dismissed")
        |> put_in(["review", "state"], "dismissed")

      GithubWebhook.handle_delivery("pull_request_review", dismissed, repo: @repo)

      # `submitted_at` does not move on a dismissal and a REST review has no
      # `updated_at`, so filing the changed body under the submission marker
      # would tell the next reader nothing had changed.
      assert {:ok, %{data: %{"state" => "DISMISSED"}, version: nil}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:pr_review, @repo, 9208))
    end

    test "a body the store cannot hold is a miss, not a half-stored resource" do
      # The store refuses a body past its size cap. A delivery is the one writer
      # that cannot be retried, so the refusal must leave a clean miss the reader
      # can act on rather than a truncated body it cannot detect.
      huge = String.duplicate("x", 300 * 1024)

      GithubWebhook.handle_delivery(
        "issue_comment",
        put_in(issue_comment_delivery(9209), ["comment", "body"], huge),
        repo: @repo
      )

      assert :miss = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_comment, @repo, 9209))
      # The issue rode along on the same delivery and is well within the cap.
      assert {:ok, _entry} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue, @repo, 42))
    end

    test "a malformed or unsupported delivery deposits nothing and does not raise" do
      assert %{status: :dropped} =
               GithubWebhook.handle_delivery("issue_comment", %{"repository" => %{"full_name" => @repo}}, repo: @repo)

      assert %{status: :error} =
               GithubWebhook.handle_delivery(
                 "issue_comment",
                 %{"repository" => %{"full_name" => @repo}, "action" => "created"},
                 repo: @repo
               )

      assert %{status: :dropped} =
               GithubWebhook.handle_delivery("deployment_status", %{"repository" => %{"full_name" => @repo}}, repo: @repo)

      assert ResourceStore.size() == 0
    end
  end

  describe "ordering — a delayed delivery cannot walk a resource backwards" do
    test "an older snapshot of the same issue is refused" do
      # Two deliveries carry the issue: a label change, then a comment delivery
      # that was delayed and is still holding the pre-change label set.
      GithubWebhook.handle_delivery(
        "issues",
        put_in(issues_delivery("labeled"), ["issue", "updated_at"], "2026-06-24T13:00:00Z"),
        repo: @repo,
        reconcile_fun: fn _ -> :ok end
      )

      stale =
        9801
        |> issue_comment_delivery()
        |> put_in(["issue", "updated_at"], "2026-06-24T09:00:00Z")
        |> put_in(["issue", "labels"], [%{"name" => "agent:ci-wait"}])

      GithubWebhook.handle_delivery("issue_comment", stale, repo: @repo)

      # The newer state stands, and is still described by its own version.
      assert {:ok, %{data: [%{"name" => "agent:in-progress"}], version: "2026-06-24T13:00:00Z"}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:issue_labels, @repo, 42))

      # The comment the delayed delivery was actually about is still deposited:
      # nothing older was held for it.
      assert {:ok, %{data: %{"id" => 9801}}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_comment, @repo, 9801))
    end

    test "an equal version still writes, because the body may have changed under it" do
      GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9802, "first"), repo: @repo)

      same_version =
        9802
        |> issue_comment_delivery("second")
        |> Map.put("action", "edited")

      GithubWebhook.handle_delivery("issue_comment", same_version, repo: @repo)

      assert {:ok, %{data: %{"body" => "second"}}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:issue_comment, @repo, 9802))
    end
  end

  describe "R5 — the deposit publishes the change" do
    test "a subscribed view is woken by the delivery's deposit with no read of its own" do
      key = ResourceStore.key_for_repo(:issue_comment, @repo, 9301)
      :ok = ResourceStore.subscribe(key)

      GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9301), repo: @repo)

      assert_receive {:github_resource_changed, %{key: ^key}}, 1_000
    end

    test "a whole-type subscriber is woken for the issue the delivery carried" do
      :ok = ResourceStore.subscribe_type(:issue)

      GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9302), repo: @repo)

      assert_receive {:github_resource_changed, %{key: {:issue, "owner", "repo", "42"}}}, 1_000
    end
  end

  describe "KTD5 — a deposit never advances a suppression mark" do
    test "the deposited body is held without marking the resource processed" do
      key = ResourceStore.key_for_repo(:issue_comment, @repo, 9401)

      # The publish is stubbed out so only the deposit runs. This is the
      # delivery of a comment nothing has handled yet.
      GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9401),
        repo: @repo,
        publish_fun: fn _topic, _payload, _opts -> :filtered end
      )

      # The body is held...
      assert {:ok, %{data: %{"id" => 9401}}} = ResourceStore.fetch(key)
      # ...and the resource is still unprocessed, at its own version and at any
      # other. A mark here would let the sweep skip a comment nothing handled.
      refute ResourceStore.processed?(key, "2026-06-24T12:00:00Z")
      refute ResourceStore.processed?(key, nil)
    end

    test "an older sibling stays recoverable after a newer one was delivered" do
      # The hazard a timestamp watermark has and identity-plus-version does not:
      # 9403 was delivered, 9402 was lost, and the sweep must still find 9402.
      :ok = Exchange.subscribe(@topic)

      assert %{status: :published} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9403, "newer"), repo: @repo)

      assert %{comment: %{"id" => 9403}} = await_event(@topic)

      {_calls, result} =
        sweep([
          comment(9402, "older, lost", "2026-06-24T11:30:00Z"),
          comment(9403, "newer", "2026-06-24T12:00:00Z")
        ])

      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9402}} = await_event(@topic)
    end
  end

  describe "A8 — an edited resource is not suppressed" do
    test "an edit replaces the body and republishes at the new version" do
      :ok = Exchange.subscribe(@topic)
      key = ResourceStore.key_for_repo(:issue_comment, @repo, 9501)

      assert %{status: :published} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9501, "first"), repo: @repo)

      assert %{comment: %{"body" => "first"}} = await_event(@topic)
      assert ResourceStore.processed?(key, "2026-06-24T12:00:00Z")

      edited =
        9501
        |> issue_comment_delivery("corrected")
        |> Map.put("action", "edited")
        |> put_in(["comment", "updated_at"], "2026-06-24T14:00:00Z")

      # Only the durable store is under test here. The in-memory replay window
      # keys on the comment id alone, so it would suppress the edit whatever the
      # store said — and it empties on every daemon restart, which is the state
      # this asserts against.
      clear_dedup()

      assert %{status: :published} = GithubWebhook.handle_delivery("issue_comment", edited, repo: @repo)

      # The event fired again — the changed `updated_at` invalidated the mark.
      assert %{comment: %{"body" => "corrected"}} = await_event(@topic)
      # And the store now serves the edited body, at the edited version.
      assert {:ok, %{data: %{"body" => "corrected"}, version: "2026-06-24T14:00:00Z"}} = ResourceStore.fetch(key)
    end
  end

  # KTD4, guarded rather than introduced here: the sweep this exercises is the
  # existing comment poller, and these cases assert the deposit did not change
  # what it recovers. They would pass against an implementation that deposited
  # nothing, which is the point — that is the behavior the deposit must preserve.
  describe "A6 — a lost delivery is still recovered by the sweep" do
    test "a comment whose delivery never arrived is published by the sweep, which still reads" do
      :ok = Exchange.subscribe(@topic)

      {calls, result} = sweep([comment(9601, "the 502'd one")])

      # KTD4: the store is a cache with reconciliation. The sweep is not
      # conditional on webhook transport, so a lost delivery costs a read and
      # loses nothing.
      assert length(calls) == 1
      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9601}} = await_event(@topic)
    end

    test "a delivery-populated entry does not stop the sweep from reading" do
      :ok = Exchange.subscribe(@topic)

      assert %{status: :published} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9602), repo: @repo)

      assert %{comment: %{"id" => 9602}} = await_event(@topic)

      {calls, result} = sweep([comment(9602, "review this"), comment(9603, "lost sibling")])

      # The read still happens — that is what makes recovery possible at all —
      # the delivered comment is not published twice, and the sibling nobody
      # delivered is recovered.
      assert length(calls) == 1
      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9603}} = await_event(@topic)
      refute_event(@topic)
    end
  end

  describe "the bot self-loop stays suppressed" do
    test "a delivery for Aiur's own comment caches the body and wakes nobody" do
      :ok = Exchange.subscribe(@topic)
      key = ResourceStore.key_for_repo(:issue_comment, @repo, 9701)

      delivery = issue_comment_delivery(9701, "posted by the fleet", @bot)

      # No publish: the actor is the configured `bot_account`.
      assert %{status: :published, published: []} = GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)

      refute_event(@topic)

      # The body is cached, because a change Aiur made is exactly the change it
      # should never have to read back...
      assert {:ok, %{data: %{"body" => "posted by the fleet"}}} = ResourceStore.fetch(key)

      # ...and the deposit did not mark it processed, so the filter — not the
      # store — is still what suppresses the self-loop.
      refute ResourceStore.processed?(key, "2026-06-24T12:00:00Z")
    end

    # Guards the surrounding filter, not the deposit: a deposit that started
    # marking resources processed would still leave this passing, which is why
    # the `refute processed?` assertion above is the one that pins the invariant.
    test "the self-loop stays filtered on redelivery of the same comment" do
      :ok = Exchange.subscribe(@topic)
      delivery = issue_comment_delivery(9702, "posted by the fleet", @bot)

      assert %{status: :published, published: []} = GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)
      assert %{status: :published, published: []} = GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)

      refute_event(@topic)
    end
  end

  # -- helpers ---------------------------------------------------------------

  # The read-through a consumer performs: consult the store, and call the fetcher
  # only on a miss. The fetcher stands in for the upstream read — every
  # invocation of it is one request the consumer had to pay for — so the count it
  # returns is the number of upstream calls serving this resource cost.
  # Goes through the real read-before-spend path rather than a `case` the test
  # wrote for itself. That distinction is the whole assertion: counting a
  # test-local closure only ever proves `ResourceStore.fetch/1` did not miss,
  # whereas `ResourceFetch.need/3`'s fetcher is the one seam an upstream request
  # would actually leave through — so a zero here is a zero on the rate limit.
  # Derived by driving real deliveries through `Deposit.deposit/3` and reading
  # back the keys it reports writing, rather than by restating a list. A list
  # would agree with the table by construction and prove nothing.
  @deliveries [
    {"issue_comment", :issue_comment_delivery},
    {"issues", :issues_delivery},
    {"pull_request_review_comment", :review_comment_delivery},
    {"pull_request_review", :review_delivery},
    {"pull_request", :pull_request_delivery},
    {"check_run", :check_run_delivery}
  ]

  defp deposited_keys do
    Enum.flat_map(@deliveries, fn {event, fixture} -> deposit_fixture(event, fixture) end)
  end

  defp deposited_types, do: deposited_keys() |> Enum.map(fn {type, _id, _key} -> type end) |> MapSet.new()

  defp deposited_keys_by_type do
    deposited_keys()
    |> Enum.group_by(fn {type, _id, _key} -> type end, fn {_type, _id, key} -> key end)
    |> Map.new(fn {type, keys} -> {type, MapSet.new(keys)} end)
  end

  defp read_by_types do
    reachability()
    |> Enum.filter(&match?({_type, {:read_by, _who, _fun}}, &1))
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp deposit_fixture(event, fixture) do
    payload =
      case fixture do
        :issue_comment_delivery -> issue_comment_delivery(9401)
        :issues_delivery -> issues_delivery("edited")
        :review_comment_delivery -> review_comment_delivery(9402)
        :review_delivery -> review_delivery(9403)
        :pull_request_delivery -> pull_request_delivery()
        :check_run_delivery -> check_run_delivery(9404)
      end

    event
    |> GithubWebhook.Deposit.deposit(payload, @repo)
    |> Enum.map(fn {type, _owner, _repo, id} = key -> {type, id, key} end)
  end

  # Every module that constructs a key of `type` in order to *use* one, which is
  # every construction site outside the writers. Scanning the source is the only
  # way to assert the absence of a reader: a runtime check can only see the
  # readers that happen to run.
  @writer_files ~w(deposit.ex write_through.ex normalizer.ex resource_store.ex resource_events.ex)
  @lib_root Path.expand("../../../../lib", __DIR__)

  defp reader_sites(type) do
    pattern = ~r/ResourceStore\.key(_for_repo)?\(:#{type}\b/

    @lib_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) in @writer_files))
    |> Enum.filter(&Regex.match?(pattern, File.read!(&1)))
    |> Enum.map(&Path.relative_to(&1, @lib_root))
    |> Enum.sort()
  end

  defp read_through(key) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fetcher = fn _opts ->
      Agent.update(counter, &(&1 + 1))
      {:ok, :fetched_from_github}
    end

    {:ok, body, meta} = ResourceFetch.need(key, fetcher, freshness: :any)

    calls = Agent.get(counter, & &1)
    Agent.stop(counter)

    # `spent?` and the call count are two independent witnesses of the same
    # fact; they must never disagree.
    assert meta.spent? == calls > 0

    {calls, body}
  end

  # One comment-poll cycle against a recording request stub, returning
  # {requests, result} exactly as the reconciliation suite does, so a request
  # count here means the same thing it means there.
  defp sweep(comments) do
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    request_fun = fn request ->
      Agent.update(recorder, &(&1 ++ [request]))
      {:ok, %{status: 200, body: comments, headers: [{"etag", ~s("v1")}]}}
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

  defp issue_comment_delivery(id, body \\ "review this", author \\ @human) do
    %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "issue" => issue(),
      "comment" => comment(id, body, "2026-06-24T12:00:00Z", author),
      "sender" => %{"login" => author}
    }
  end

  defp issues_delivery(action) do
    %{
      "action" => action,
      "repository" => %{"full_name" => @repo},
      "issue" => issue(),
      "sender" => %{"login" => @human}
    }
  end

  defp review_comment_delivery(id) do
    %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "pull_request" => pull_request(),
      "comment" => comment(id, "inline note", "2026-06-24T12:00:00Z", @human),
      "sender" => %{"login" => @human}
    }
  end

  defp review_delivery(id) do
    %{
      "action" => "submitted",
      "repository" => %{"full_name" => @repo},
      "pull_request" => pull_request(),
      "review" => %{
        "id" => id,
        "state" => "changes_requested",
        "body" => "needs work",
        "submitted_at" => "2026-06-24T12:30:00Z",
        "user" => %{"login" => @human}
      },
      "sender" => %{"login" => @human}
    }
  end

  defp pull_request_delivery do
    %{
      "action" => "opened",
      "repository" => %{"full_name" => @repo},
      "pull_request" => pull_request(),
      "sender" => %{"login" => @human}
    }
  end

  defp check_run_delivery(id) do
    %{
      "action" => "completed",
      "repository" => %{"full_name" => @repo},
      "check_run" => %{
        "id" => id,
        "name" => "test",
        "conclusion" => "success",
        "head_sha" => "abc123",
        "started_at" => "2026-06-24T12:50:00Z",
        "completed_at" => "2026-06-24T13:00:00Z",
        "pull_requests" => [pull_request()]
      },
      "sender" => %{"login" => @human}
    }
  end

  defp issue do
    %{
      "number" => 42,
      "title" => "a ticket",
      "body" => "the ask",
      "state" => "open",
      "updated_at" => "2026-06-24T11:00:00Z",
      "labels" => [%{"name" => "agent:in-progress"}]
    }
  end

  defp pull_request do
    %{
      "number" => 77,
      "state" => "open",
      "updated_at" => "2026-06-24T11:30:00Z",
      "head" => %{"ref" => "aiur/42-a-ticket", "sha" => "abc123"}
    }
  end

  defp comment(id, body, updated_at \\ "2026-06-24T12:00:00Z", author \\ @human) do
    %{
      "id" => id,
      "body" => body,
      "created_at" => updated_at,
      "updated_at" => updated_at,
      "html_url" => "https://example.test/comments/#{id}",
      "user" => %{"login" => author}
    }
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

  # Restarts the store against a real checkpoint file: with no resolvable state
  # directory it runs in memory, which would make a restart trivially pass
  # nothing rather than prove the round trip.
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

  defp clear_dedup do
    case :ets.whereis(@dedup_table) do
      :undefined -> :ok
      _table -> :ets.delete_all_objects(@dedup_table)
    end

    :ok
  end
end
