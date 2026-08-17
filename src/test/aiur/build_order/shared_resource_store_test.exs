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

  alias Aiur.GitHub.{Issues, ResourceStore}

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @repository {"owner", "repo"}

  # The staleness a reader states it can accept. There is no default: a caller
  # that says nothing gets a conditional request rather than an arbitrarily old
  # body, which is the "never a silent guess" half of R7 and is pinned below.
  @tolerance_ms 30_000

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    ResourceStore.reset()

    {:ok, requests: start_recorder()}
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

    # A restart keeps validators and drops bodies. A `304` then has nothing to
    # serve, and the only correct recovery is the unconditional request the
    # caller would have made anyway — never an error surfaced to the page.
    test "a 304 with no stored body recovers by re-asking rather than failing" do
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
      assert count(recorder) == 3
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

  describe "failing open" do
    test "with no store running the read is unconditional, exactly as before" do
      recorder = start_recorder()
      request_fun = recording_fun(recorder, fn _request -> ok_issue(7) end)
      opts = [repository: @repository, request_fun: request_fun, freshness_ms: @tolerance_ms]

      assert {:ok, _body, :fetched} = Issues.fetch_issue_raw_conditional(7, opts)

      # Simulate the store being unavailable by clearing everything it knows.
      ResourceStore.reset()

      assert {:ok, _body, :fetched} = Issues.fetch_issue_raw_conditional(7, opts)
      assert count(recorder) == 2
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp issue_body(number) do
    %{
      "number" => number,
      "title" => "Ticket #{number}",
      "body" => "description",
      "html_url" => "https://github.com/owner/repo/issues/#{number}",
      "labels" => [%{"name" => "sym:todo"}],
      "assignee" => nil,
      "created_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-02T00:00:00Z"
    }
  end

  defp ok_issue(number) do
    {:ok, %{status: 200, headers: [{"etag", "\"v1\""}], body: issue_body(number)}}
  end

  defp start_recorder do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    pid
  end

  defp recording_fun(recorder, fun) do
    fn request ->
      Agent.update(recorder, &[request | &1])
      fun.(request)
    end
  end

  defp requests(recorder), do: recorder |> Agent.get(& &1) |> Enum.reverse()
  defp count(recorder), do: recorder |> requests() |> length()

  # Reads of the issue resource itself, which is what these tests are about.
  #
  # The dispatch poll additionally reads `/issues/{n}/timeline` through
  # `Aiur.GitHub.DispatchAuthorization`. That is a genuinely different resource,
  # not a duplicate of this one, so counting it here would hide the thing being
  # measured. It is also still unconditional — named in the PR rather than
  # folded into a percentage, and out of scope for this change.
  defp issue_requests(recorder) do
    recorder
    |> requests()
    |> Enum.filter(&String.match?(&1.url, ~r{/issues/\d+$}))
  end

  defp issue_count(recorder), do: recorder |> issue_requests() |> length()
end
