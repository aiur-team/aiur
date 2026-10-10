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

  use Aiur.TestSupport.DepositCase

  alias Aiur.Events.GithubWebhook
  alias Aiur.GitHub.{ResourceFetch, ResourceStore}

  @repo "owner/repo"

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
      number = ticket_number()

      assert %{status: :published} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9102), repo: @repo)

      {calls, issue} = read_through(ResourceStore.key_for_repo(:issue, @repo, number))

      assert calls == 0
      assert %{"number" => ^number} = issue
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

  # Acceptance #2126-2. A strict read never serves from the store (R10), but a
  # `304` is a fresh answer GitHub asserts *right now*, so it is free against the
  # primary rate limit. For a strict read to revalidate, the store must hold a
  # validator beside the deposited body — which is exactly what a plain deposit
  # did not leave behind. The deposit now derives one (`etag: :derive`), and this
  # is the property asserted: call count and the conditional header.
  describe "a strict read of a webhook-deposited resource revalidates" do
    test "sends If-None-Match and a 304 costs nothing" do
      number = ticket_number()
      GithubWebhook.handle_delivery("pull_request", pull_request_delivery(), repo: @repo)
      key = ResourceStore.key_for_repo(:branch_pull_request, @repo, number)

      validator = ResourceStore.etag(key)
      assert is_binary(validator) and validator != "", "the deposit must leave a validator beside the body"

      {:ok, calls} = Agent.start_link(fn -> %{count: 0, opts: []} end)

      fetcher = fn opts ->
        Agent.update(calls, fn state -> %{count: state.count + 1, opts: state.opts ++ [opts]} end)
        {:not_modified, Keyword.fetch!(opts, :etag)}
      end

      assert {:ok, %{"number" => 77}, meta} =
               ResourceFetch.need(key, fetcher, freshness: ResourceFetch.decision(), reason: "merge decision")

      # Upstream was asked exactly once — a strict read is a bypass, not a hint —
      # and the request carried the stored validator as `If-None-Match`.
      assert Agent.get(calls, & &1.count) == 1
      assert Agent.get(calls, & &1.opts) == [[etag: validator]]
      assert meta.outcome == :revalidated
      refute meta.spent?
    end

    test "a delivered body holds a validator the store will offer" do
      number = ticket_number()
      GithubWebhook.handle_delivery("pull_request", pull_request_delivery(), repo: @repo)

      key = ResourceStore.key_for_repo(:branch_pull_request, @repo, number)
      assert {:ok, %{data: %{"number" => 77}, etag: etag}} = ResourceStore.fetch(key)
      assert is_binary(etag) and etag != ""
    end

    # The `:derive` contract: a re-delivery of an unchanged body must keep a
    # validator a fetch already recorded — GitHub's real ETag is what actually
    # earns the free `304`, so knocking it out would turn a free read back into a
    # full-price one.
    test "an unchanged re-delivery keeps a held validator" do
      number = ticket_number()
      key = ResourceStore.key_for_repo(:branch_pull_request, @repo, number)
      GithubWebhook.handle_delivery("pull_request", pull_request_delivery(), repo: @repo)

      # A conditional reader fetches, recording GitHub's real ETag for the body.
      ResourceStore.put_resource(key, pull_request(), etag: ~s("github-real"))
      assert ResourceStore.etag(key) == ~s("github-real")

      GithubWebhook.handle_delivery("pull_request", pull_request_delivery(), repo: @repo)

      assert ResourceStore.etag(key) == ~s("github-real"),
             "an unchanged re-delivery must not replace a GitHub ETag with a derived one"
    end

    # The derived validator is content-based, so a changed body cannot keep a
    # validator that describes the previous one (the stale-validator hazard).
    test "a changed body re-derives a validator that describes it" do
      number = ticket_number()
      key = ResourceStore.key_for_repo(:branch_pull_request, @repo, number)
      GithubWebhook.handle_delivery("pull_request", pull_request_delivery(), repo: @repo)
      {:ok, %{etag: before}} = ResourceStore.fetch(key)

      changed = put_in(pull_request_delivery(), ["pull_request", "title"], "edited")
      GithubWebhook.handle_delivery("pull_request", changed, repo: @repo)

      assert {:ok, %{etag: later}} = ResourceStore.fetch(key)
      assert is_binary(later) and later != ""
      assert later != before, "a validator that describes a different body is a stale one"
    end
  end

  # A deposit nobody can address is a write to nowhere: it costs bytes against
  # the size cap and the entry ceiling, a checkpoint every 30 seconds and a
  # publish on every arrival, and returns nothing. That is not hypothetical:
  # `:pull_request` used to be deposited keyed by **pull request number** while
  # the only pull-request consumer read `:branch_pull_request` keyed by **ticket
  # number** — two pipes keyed so they could never meet. `Deposit` now files the
  # PR under both keys (#2126), and #2352's row-5 conditional read
  # (`Client.fetch_open_pull_request/2`) addresses the `:pull_request` key by PR
  # number, so the two halves meet at last.
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
      issue:
        {:read_by, "Aiur.GitHub.Issues.fetch_issue_raw_conditional/2 (issues.ex:179)",
         [
           ResourceStore.key(:issue, "owner", "repo", ticket_number()),
           # The sub_issues delivery also carries the sub-issue, which shares the
           # `:issue` reader's generic addressing.
           ResourceStore.key(:issue, "owner", "repo", 41)
         ]},
      issue_comment: {:read_by, "Aiur.Events.GithubCommentsPoller suppression marks (github_comments_poller.ex:602)", [ResourceStore.key_for_repo(:issue_comment, @repo, 9401)]},
      pr_review: {:read_by, "Aiur.Events.GithubCommentsPoller suppression marks (github_comments_poller.ex:587)", [ResourceStore.key_for_repo(:pr_review, @repo, 9403)]},
      pr_review_comment: {:read_by, "Aiur.Events.GithubCommentsPoller suppression marks (github_comments_poller.ex:650)", [ResourceStore.key_for_repo(:pr_review_comment, @repo, 9402)]},
      issue_labels:
        {:read_by,
         "OpenTicketSource and AdHocSource refresh a held ticket/member's labels " <>
           "(open_ticket_source.ex, ad_hoc_source.ex), and the Build Order " <>
           "Reconciliation re-deposits each root's label set during the rare " <>
           "catalog reconciliation (reconciliation.ex:143)",
         [
           ResourceStore.key(:issue_labels, "owner", "repo", ticket_number()),
           # The sub_issues delivery also carries the sub-issue's labels, which
           # share the same label reader's generic addressing.
           ResourceStore.key(:issue_labels, "owner", "repo", 41)
         ]},
      pull_request: {:read_by, "Aiur.GitHub.Client.fetch_open_pull_request/2 (client.ex), the #2352 row-5 conditional read", [ResourceStore.key_for_repo(:pull_request, @repo, 77)]},
      branch_pull_request: {:read_by, "Aiur.GitHub.HumanReviewGate.open_pull_request/1 (human_review_gate.ex:106)", [ResourceStore.key_for_repo(:branch_pull_request, @repo, ticket_number())]},
      issue_blocked_by: {:read_by, "Aiur.GitHub.DependenciesApi.dependency_get/3 (dependencies_api.ex)", [ResourceStore.key(:issue_blocked_by, "owner", "repo", ticket_number())]},
      sub_issue:
        {:read_by, "Aiur.BuildOrder.CatalogStore rebuilds each root's membership from the held edges (catalog_store.ex)", [ResourceStore.key(:sub_issue, "owner", "repo", "#{ticket_id()}:41")]},
      issue_dependency:
        {:read_by, "Aiur.BuildOrder.CatalogStore rebuilds each root's dependency set from the held edges (catalog_store.ex)",
         [ResourceStore.key(:issue_dependency, "owner", "repo", "#{ticket_id()}:80")]}
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

  # Derived by driving real deliveries through `Deposit.deposit/3` and reading
  # back the keys it reports writing, rather than by restating a list. A list
  # would agree with the table by construction and prove nothing.
  @deliveries [
    {"issue_comment", :issue_comment_delivery},
    {"issues", :issues_delivery},
    {"pull_request_review_comment", :review_comment_delivery},
    {"pull_request_review", :review_delivery},
    {"pull_request", :pull_request_delivery},
    {"pull_request_review_thread", :pull_request_review_thread_delivery},
    {"sub_issues", :sub_issues_delivery},
    {"issue_dependencies", :issue_dependencies_delivery}
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
        :pull_request_review_thread_delivery -> pull_request_review_thread_delivery()
        :sub_issues_delivery -> sub_issues_delivery()
        :issue_dependencies_delivery -> issue_dependencies_delivery()
      end

    seed_for_fixture(fixture)

    event
    |> GithubWebhook.Deposit.deposit(payload, @repo)
    |> Enum.map(fn {type, _owner, _repo, id} = key -> {type, id, key} end)
  end

  # A lone `blocked_by_added` merge never starts a list from one edge (review
  # #2332): the deposit→read link the reachability table asserts exists only
  # once the store holds a complete list — the baseline a full `GET blocked_by`
  # 200 writes. Seed that baseline so the fixture's merge lands and the table
  # keeps proving the two pipes share a key.
  defp seed_for_fixture(:issue_dependencies_delivery) do
    number = ticket_number()
    key = ResourceStore.key_for_repo(:issue_blocked_by, @repo, number)
    ResourceStore.put_resource(key, [], source: :fetch, etag: ~s("baseline"))
    :ok
  end

  defp seed_for_fixture(_fixture), do: :ok

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
end
