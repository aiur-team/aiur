defmodule Aiur.GitHub.DispatchAuthorization.CacheTest do
  import Aiur.GitHub.DispatchAuthorization.TestFixtures
  import ExUnit.CaptureLog

  use Aiur.TestSupport

  alias Aiur.AgentPubSub
  alias Aiur.GitHub.DispatchAuthorization
  alias Aiur.GitHub.ReadCache

  setup do
    DispatchAuthorization.clear_cache()
    :ok
  end

  test "caches an unchanged issue's latest label event" do
    counter = start_supervised!({Agent, fn -> 0 end})
    events = [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]

    request_fun = fn %{url: url} ->
      assert url =~ "/issues/42/timeline"
      Agent.update(counter, &(&1 + 1))
      {:ok, %{status: 200, body: events}}
    end

    issue = issue()

    assert DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    assert DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
             allowed_users: ["trusted"],
             request_fun: request_fun
           ).dispatch_authorized?

    assert Agent.get(counter, & &1) == 1
  end

  test "a label event indexed after issue creation authorizes on the next poll without an issue update" do
    ReadCache.reset()
    on_exit(&ReadCache.reset/0)
    counter = start_supervised!({Agent, fn -> 0 end})
    parent = self()

    request_fun = fn request ->
      ReadCache.through(request, fn ->
        poll = Agent.get_and_update(counter, fn count -> {count, count + 1} end)
        send(parent, {:timeline_poll, poll})

        events =
          if poll == 0,
            do: [],
            else: [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:01Z")]

        {:ok, %{status: 200, body: events}}
      end)
    end

    created_with_label = issue(creator_login: "trusted")

    first =
      DispatchAuthorization.authorize(created_with_label, "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: request_fun
      )

    refute first.dispatch_authorized?
    assert first.dispatch_authorization == :deferred
    assert_receive {:timeline_poll, 0}, 1000

    second =
      DispatchAuthorization.authorize(created_with_label, "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: request_fun
      )

    assert second.dispatch_authorized?
    assert second.dispatch_authorization == :authorized
    assert_receive {:timeline_poll, 1}, 1000
  end

  test "does not reuse a cached decision after an issue update" do
    counter = start_supervised!({Agent, fn -> 0 end})

    request_fun = fn _request ->
      request_number = Agent.get_and_update(counter, fn number -> {number, number + 1} end)

      events =
        if request_number == 0 do
          [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]
        else
          [labeled_event(11, "agent:todo", "outsider", "2026-01-02T00:00:00Z")]
        end

      {:ok, %{status: 200, body: events}}
    end

    assert DispatchAuthorization.authorize(issue(updated_at: ~U[2026-01-01 00:00:00Z]), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    refute DispatchAuthorization.authorize(issue(updated_at: ~U[2026-01-02 00:00:00Z]), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    assert Agent.get(counter, & &1) == 2
  end

  # #2298 item 2: the timeline read carries a validator, so a repeat dispatch
  # whose decision-cache fingerprint moved (the issue updated) but whose
  # timeline is unchanged revalidates with `If-None-Match` and reuses the held
  # timeline instead of refetching it at full price.
  test "a repeat dispatch on an unchanged issue revalidates rather than refetches" do
    parent = self()
    etag = ~s("timeline-v1")
    events = [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]

    request_fun = fn request ->
      case Map.get(request, :etag) do
        nil ->
          send(parent, :unconditional)
          {:ok, %{status: 200, headers: [{"etag", etag}], body: events}}

        ^etag ->
          send(parent, :conditional)
          {:ok, %{status: 304, headers: [{"etag", etag}]}}

        other ->
          flunk("unexpected If-None-Match validator #{inspect(other)}")
      end
    end

    assert DispatchAuthorization.authorize(issue(updated_at: ~U[2026-01-01 00:00:00Z]), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    assert_receive :unconditional, 1000

    assert DispatchAuthorization.authorize(issue(updated_at: ~U[2026-01-02 00:00:00Z]), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    assert_receive :conditional, 1000
  end

  # #2298 rework B1: a page-1 `304` only vouches for the page it names. Issue
  # timelines are ordered oldest-first, so new `labeled` events land on the last
  # page; a multi-page held timeline must therefore be refetched every cycle —
  # never answered from a validator that cannot see the newer pages.
  test "a multi-page timeline is refetched, never answered from a page-1 304" do
    etag = ~s("timeline-v1")
    first_page = [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]
    second_page = [labeled_event(11, "agent:todo", "outsider", "2026-01-02T00:00:00Z")]
    next = ~s(<https://api.github.com/repos/owner/repo/issues/42/timeline?per_page=100&page=2>; rel="next")

    counter = start_supervised!({Agent, fn -> 0 end})

    request_fun = fn request ->
      refute Map.has_key?(request, :etag),
             "a multi-page held timeline must never revalidate page 1"

      case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
        0 -> {:ok, %{status: 200, headers: [{"etag", etag}, {"link", next}], body: first_page}}
        1 -> {:ok, %{status: 200, headers: [], body: second_page}}
        2 -> {:ok, %{status: 200, headers: [{"etag", etag}, {"link", next}], body: first_page}}
        3 -> {:ok, %{status: 200, headers: [], body: second_page}}
      end
    end

    # Cycle 1: two pages, so the latest `agent:todo` applier is the outsider.
    refute DispatchAuthorization.authorize(issue(updated_at: ~U[2026-01-01 00:00:00Z]), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    # Cycle 2 with a moved decision-cache fingerprint: the held timeline spanned
    # two pages, so the read refetches both — and still sees the outsider's
    # label, proving it was not answered from a stale held snapshot.
    refute DispatchAuthorization.authorize(issue(updated_at: ~U[2026-01-03 00:00:00Z]), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    assert Agent.get(counter, & &1) == 4
  end

  # #2298 rework B1: the single→multi transition. Page 1 answers `304` but now
  # carries a `next` link, which means the timeline grew a page the held single
  # page cannot see. The read must refetch rather than serve the held snapshot.
  test "a single-page 304 that reports a new page is refetched, not reused" do
    parent = self()
    etag = ~s("timeline-v1")
    next = ~s(<https://api.github.com/repos/owner/repo/issues/42/timeline?per_page=100&page=2>; rel="next")

    request_fun = fn request ->
      case Map.get(request, :etag) do
        nil ->
          send(parent, :unconditional)
          {:ok, %{status: 200, headers: [{"etag", etag}], body: [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]}}

        ^etag ->
          send(parent, :conditional)
          {:ok, %{status: 304, headers: [{"etag", etag}, {"link", next}]}}

        other ->
          flunk("unexpected If-None-Match validator #{inspect(other)}")
      end
    end

    assert DispatchAuthorization.authorize(issue(updated_at: ~U[2026-01-01 00:00:00Z]), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    assert_receive :unconditional, 1000

    # The fingerprint moved; page 1 304s but reports a new page, so the held
    # single page cannot be trusted and the whole timeline is refetched.
    assert DispatchAuthorization.authorize(issue(updated_at: ~U[2026-01-02 00:00:00Z]), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    assert_receive :conditional, 1000
    assert_receive :unconditional, 1000
  end

  # #2409: a rate-limited provenance fetch is a *resource* failure, not a
  # provenance finding. The ticket is not dispatched this cycle (fail-closed)
  # but is marked `:deferred` — no ambiguous-attention alert, and no verdict
  # that could be read as revoked — and the next poll re-verifies from a fresh
  # timeline. Before this change a transient throttle was reported as "label
  # provenance could not be verified" and the deny could kill a running agent
  # and exhaust its retry budget.
  test "a rate-limited timeline fetch defers, then re-authorizes on the next poll" do
    counter = start_supervised!({Agent, fn -> 0 end})

    request_fun = fn _request ->
      case Agent.get_and_update(counter, fn number -> {number, number + 1} end) do
        0 -> {:ok, %{status: 429, body: %{"message" => "rate limited"}}}
        1 -> {:ok, %{status: 200, body: [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]}}
      end
    end

    :ok = AgentPubSub.subscribe_agent("42")
    issue = issue()

    log =
      capture_log(fn ->
        deferred =
          DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
            allowed_users: ["trusted"],
            token: "test-token",
            request_fun: request_fun
          )

        refute deferred.dispatch_authorized?
        assert deferred.dispatch_authorization == :deferred
      end)

    assert log =~ "timeline_fetch_failed"

    # A deferred authorization is not a provenance ambiguity, so it raises no
    # `ambiguous` needs-attention alert.
    refute_receive {:alert, %{name: "github.dispatch_authorization.ambiguous", needs_attention: true}}, 100

    assert DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    assert Agent.get(counter, & &1) == 2
  end

  # #2409 acceptance: a simulated budget hold during dispatch authorization
  # leaves the ticket dispatchable once the hold lifts, with no operator
  # action. This is the incident's exact transport shape —
  # `{:aiur, :locally_held, %{reason: :shared_budget, resource: "core"}}` —
  # which now *defers* instead of denying: no provenance alert, and the next
  # poll re-verifies to `:authorized`.
  test "a local budget hold on the timeline fetch defers, not denies, then re-authorizes" do
    counter = start_supervised!({Agent, fn -> 0 end})
    hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 30, :second)}

    request_fun = fn _request ->
      case Agent.get_and_update(counter, fn number -> {number, number + 1} end) do
        0 -> {:error, {:aiur, :locally_held, hold}}
        1 -> {:ok, %{status: 200, body: [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]}}
      end
    end

    :ok = AgentPubSub.subscribe_agent("42")
    issue = issue()

    log =
      capture_log(fn ->
        deferred =
          DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
            allowed_users: ["trusted"],
            token: "test-token",
            request_fun: request_fun,
            local_hold_max_wait_ms: 100,
            local_hold_sleep_fun: fn _ms -> flunk("a hold beyond the local wait ceiling must fail closed") end
          )

        refute deferred.dispatch_authorized?
        assert deferred.dispatch_authorization == :deferred
      end)

    assert log =~ "timeline_fetch_failed"
    refute_receive {:alert, %{name: "github.dispatch_authorization.ambiguous", needs_attention: true}}, 100

    authorized =
      DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: request_fun
      )

    assert authorized.dispatch_authorized?
    assert authorized.dispatch_authorization == :authorized
  end
end
