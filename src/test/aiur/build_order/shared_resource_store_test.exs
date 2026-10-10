defmodule Aiur.BuildOrder.SharedResourceStoreTest do
  @moduledoc """
  Proves that Build Order and the daemon's per-issue reconciliation poll share
  one GitHub read.

  Every assertion here counts requests. That is deliberate: latency cannot tell a
  `304` from a `200`, and a module reporting its own cache-hit rate is marking its
  own homework. The transport stub is the only witness that cannot be fooled —
  if it was not called, no quota was spent.
  """

  use Aiur.TestSupport

  import Aiur.BuildOrder.SharedResourceStoreSupport

  alias Aiur.BuildOrder.TicketDetail
  alias Aiur.GitHub.Issues
  alias Aiur.GitHub.ResourceStore

  @repository {"owner", "repo"}
  # The staleness a reader states it can accept. There is no default: a caller
  # that says nothing gets a conditional request rather than an arbitrarily old
  # body, which is the "never a silent guess" half of R7 and is pinned below.
  @tolerance_ms 30_000

  setup do
    {:ok, requests: prepare_shared_store()}
  end

  describe "criterion 2 — two opens inside the freshness window issue one read" do
    test "the second Build Order read of the same ticket issues no request at all" do
      recorder = start_recorder()
      request_fun = recording_fun(recorder, fn _request -> ok_issue(7) end)
      opts = [repository: @repository, request_fun: request_fun, freshness_ms: @tolerance_ms]

      assert {:ok, %{"number" => 7}, :fetched} = Issues.fetch_issue_raw_conditional(7, opts)
      assert {:ok, %{"number" => 7}, :fresh} = Issues.fetch_issue_raw_conditional(7, opts)

      assert count(recorder) == 1
    end

    # The window is the caller's, not the store's. A caller stating a tolerance
    # shorter than the body's age must be given a conditional request, or
    # `:freshness_ms` would be decoration and any held body would be served
    # forever.
    test "a body older than the stated tolerance is revalidated, not served" do
      recorder = start_recorder()

      request_fun =
        recording_fun(recorder, fn request ->
          case Map.get(request, :etag) do
            nil -> {:ok, %{status: 200, headers: [{"etag", "\"v1\""}], body: issue_body(7)}}
            "\"v1\"" -> {:ok, %{status: 304, headers: [{"etag", "\"v1\""}]}}
          end
        end)

      # A zero-length window: whatever is held is already too old.
      opts = [repository: @repository, request_fun: request_fun, freshness_ms: 1]

      assert {:ok, _body, :fetched} = Issues.fetch_issue_raw_conditional(7, opts)
      Process.sleep(5)
      assert {:ok, %{"number" => 7}, :not_modified} = Issues.fetch_issue_raw_conditional(7, opts)

      assert [_paid, revalidation] = issue_requests(recorder)
      assert revalidation.etag == "\"v1\""
    end

    # R7's "never a silent guess": a caller that states no tolerance is not
    # handed a body of unknown age. It gets the conditional request, which is
    # free when nothing changed.
    test "a caller stating no tolerance gets a conditional request, not a held body" do
      recorder = start_recorder()

      request_fun =
        recording_fun(recorder, fn request ->
          case Map.get(request, :etag) do
            nil -> {:ok, %{status: 200, headers: [{"etag", "\"v1\""}], body: issue_body(7)}}
            "\"v1\"" -> {:ok, %{status: 304, headers: [{"etag", "\"v1\""}]}}
          end
        end)

      opts = [repository: @repository, request_fun: request_fun]

      assert {:ok, _body, :fetched} = Issues.fetch_issue_raw_conditional(7, opts)
      assert {:ok, %{"number" => 7}, :not_modified} = Issues.fetch_issue_raw_conditional(7, opts)

      assert issue_count(recorder) == 2
    end

    # A cache nobody can bypass is a bug. A caller that wants to be *sure* says
    # so and gets a request — which is still free when nothing changed.
    test "a caller asking to revalidate always issues a request" do
      recorder = start_recorder()
      request_fun = recording_fun(recorder, fn _request -> ok_issue(7) end)
      opts = [repository: @repository, request_fun: request_fun, revalidate: true]

      assert {:ok, _body, :fetched} = Issues.fetch_issue_raw_conditional(7, opts)
      assert {:ok, _body, :fetched} = Issues.fetch_issue_raw_conditional(7, opts)

      assert count(recorder) == 2
    end
  end

  # The seam, not just the endpoint. `Issues.fetch_issue_raw_conditional/2` can be
  # perfect and Build Order still pay full price if the coordinator's freshness
  # requirement is dropped somewhere between `TicketDetail.fetch/2` and the store
  # — which is a keyword list passed through three modules, so exactly the kind of
  # thing that is silently lost. This asserts through the real Build Order entry
  # point instead of the one below it.
  describe "the Build Order ticket-detail seam" do
    test "two detail reads of one ticket inside the window issue one request" do
      recorder = start_recorder()
      # `node_id` matters here and nowhere else in this file: the detail path
      # verifies that the body it got back really is the ticket it asked for.
      body =
        Map.merge(issue_body(42), %{
          "node_id" => "I42",
          "repository_url" => "https://api.github.com/repos/owner/repo",
          "state" => "open",
          "state_reason" => nil
        })

      request_fun = recording_fun(recorder, fn _request -> {:ok, %{status: 200, headers: [], body: body}} end)

      opts = [
        configured_repo: @repository,
        request_fun: request_fun,
        freshness_ms: @tolerance_ms,
        relationship_reader: fn _identity, _repository -> {:ok, %{nodes: [], truncated?: false}} end
      ]

      identity = ticket_identity(42, "I42")

      assert {:ok, first} = TicketDetail.fetch(identity, opts)
      assert {:ok, second} = TicketDetail.fetch(identity, opts)

      assert first.title == second.title
      assert issue_count(recorder) == 1
    end
  end

  describe "criterion 3 — an unchanged refresh spends no primary rate limit" do
    # GitHub excludes `304` from the primary REST rate limit. Proving "zero
    # quota" therefore means proving the second request carried a validator and
    # was answered `304` — and that the body still came back, because a `304`
    # that loses the body is a dropped read, not a saving.
    test "the refresh is conditional, answers 304, and still returns the body" do
      recorder = start_recorder()

      request_fun =
        recording_fun(recorder, fn request ->
          case Map.get(request, :etag) do
            nil -> {:ok, %{status: 200, headers: [{"etag", "\"v1\""}], body: issue_body(7)}}
            "\"v1\"" -> {:ok, %{status: 304, headers: [{"etag", "\"v1\""}]}}
          end
        end)

      opts = [repository: @repository, request_fun: request_fun, revalidate: true]

      assert {:ok, body, :fetched} = Issues.fetch_issue_raw_conditional(7, opts)
      assert {:ok, ^body, :not_modified} = Issues.fetch_issue_raw_conditional(7, opts)

      assert [first, second] = issue_requests(recorder)
      refute Map.has_key?(first, :etag)
      assert second.etag == "\"v1\""
    end

    # A `304` deliberately does **not** make the held body fresh again.
    #
    # Re-depositing the body to move its clock is a read-then-write whose two
    # halves can be split by a concurrent delivery, and the store takes the
    # version as a fixed option while the body comes from the entry — so the pair
    # can end up describing different objects. The concurrency test below is what
    # ruled that out. What is written back is the validator alone, so the entry
    # stays coherent and the next read past its window costs one more conditional
    # request, which answers `304` and spends no primary rate limit.
    test "a 304 retains the validator without restamping the body" do
      key = ResourceStore.key(:issue, "owner", "repo", "7")
      recorder = start_recorder()

      request_fun =
        recording_fun(recorder, fn request ->
          case Map.get(request, :etag) do
            nil -> {:ok, %{status: 200, headers: [{"etag", "\"v1\""}], body: issue_body(7)}}
            "\"v1\"" -> {:ok, %{status: 304, headers: [{"etag", "\"v2\""}]}}
          end
        end)

      base = [repository: @repository, request_fun: request_fun]
      assert {:ok, _body, :fetched} = Issues.fetch_issue_raw_conditional(7, base)
      assert {:ok, deposited} = ResourceStore.fetch(key)

      Process.sleep(5)
      assert {:ok, _body, :not_modified} = Issues.fetch_issue_raw_conditional(7, base ++ [revalidate: true])

      # The newer validator is kept, and nothing else about the entry moved.
      assert {:ok, refreshed} = ResourceStore.fetch(key)
      assert refreshed.etag == "\"v2\""
      assert refreshed.data == deposited.data
      assert refreshed.version == deposited.version

      # `fetched_at_ms` is the assertion that actually pins this. Everything above
      # also holds for a re-deposit of an identical body; only an untouched clock
      # proves the body was not written back at all, which is the property that
      # makes the entry uncorruptible by a concurrent delivery.
      assert refreshed.fetched_at_ms == deposited.fetched_at_ms
    end

    # A restart keeps validators and drops bodies, and a validator without a body
    # is worse than useless: it buys a guaranteed `304` that carries nothing, and
    # then the recovery spends a second, unconditional request. Two requests where
    # one was needed is the precise waste this store exists to remove.
    #
    # So the validator is offered only alongside a body the store will actually
    # serve. This asserts the request count *and* that the surviving request
    # carried no validator, because the count alone would also pass if the read
    # had failed outright.
    test "a body-less validator is not sent, so the recovery costs one request" do
      recorder = start_recorder()

      request_fun =
        recording_fun(recorder, fn request ->
          if Map.has_key?(request, :etag) do
            {:ok, %{status: 304, headers: [{"etag", "\"v1\""}]}}
          else
            {:ok, %{status: 200, headers: [{"etag", "\"v1\""}], body: issue_body(7)}}
          end
        end)

      opts = [repository: @repository, request_fun: request_fun, revalidate: true]

      assert {:ok, _body, :fetched} = Issues.fetch_issue_raw_conditional(7, opts)

      # Exactly the post-restart shape: the validator survived, the body did not.
      ResourceStore.drop_data(ResourceStore.key(:issue, "owner", "repo", "7"))

      assert {:ok, %{"number" => 7}, :fetched} = Issues.fetch_issue_raw_conditional(7, opts)

      # Two, not three: the dropped body took its validator out of circulation, so
      # the recovery read went straight to an unconditional `200` instead of
      # spending a `304` first to learn nothing.
      assert [first, recovery] = issue_requests(recorder)
      refute Map.has_key?(first, :etag)
      refute Map.has_key?(recovery, :etag)
    end
  end

  describe "criterion 5 — the daemon poll and Build Order share one read" do
    test "a ticket the tracker already fetched is served to Build Order with no request" do
      recorder = start_recorder()
      request_fun = recording_fun(recorder, fn _request -> ok_issue(7) end)

      # The daemon's per-issue reconciliation poll, with its own empty cache.
      assert {:ok, [issue], _cache} =
               Issues.fetch_issue_states_by_ids_conditional(["7"], %{}, request_fun: request_fun)

      assert issue.id == "7"
      assert issue_count(recorder) == 1

      # Build Order now asks for the same ticket. It must cost nothing.
      assert {:ok, %{"number" => 7}, :fresh} =
               Issues.fetch_issue_raw_conditional(7,
                 repository: @repository,
                 request_fun: request_fun,
                 freshness_ms: @tolerance_ms
               )

      assert issue_count(recorder) == 1
    end

    # The other direction. Build Order pays once; the poll then revalidates for
    # free instead of paying a second full price for bytes already in the store.
    test "a ticket Build Order fetched lets the tracker poll revalidate rather than re-fetch" do
      recorder = start_recorder()

      request_fun =
        recording_fun(recorder, fn request ->
          case Map.get(request, :etag) do
            nil -> {:ok, %{status: 200, headers: [{"etag", "\"v1\""}], body: issue_body(7)}}
            "\"v1\"" -> {:ok, %{status: 304, headers: [{"etag", "\"v1\""}]}}
          end
        end)

      assert {:ok, _body, :fetched} =
               Issues.fetch_issue_raw_conditional(7,
                 repository: @repository,
                 request_fun: request_fun,
                 revalidate: true
               )

      assert {:ok, [issue], _cache} =
               Issues.fetch_issue_states_by_ids_conditional(["7"], %{}, request_fun: request_fun)

      assert issue.id == "7"

      # Two requests total: Build Order's paid read, and the poll's free `304`.
      # Three would mean the poll got a `304`, found no body, and re-asked —
      # the trap where sharing a validator without the body makes things worse.
      assert [_paid, revalidation] = issue_requests(recorder)
      assert revalidation.etag == "\"v1\""
      assert issue_count(recorder) == 2
    end
  end
end
