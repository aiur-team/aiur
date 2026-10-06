defmodule Aiur.GitHub.DispatchAuthorizationTest do
  use Aiur.TestSupport

  alias Aiur.{AgentPubSub, Issue}
  alias Aiur.GitHub.{DispatchAuthorization, ReadCache}

  setup do
    DispatchAuthorization.clear_cache()
    :ok
  end

  # Regression: an allowlisted creator used to short-circuit authorization with
  # no label check at all. Agents file issues with the same credential, so that
  # let an agent create a ticket, label it, and dispatch it with no human in the
  # loop — and it also dispatched trusted-creator issues whose trigger label was
  # applied by an outsider. Creation is not authorization; the verified label
  # applier is.
  test "an allowlisted creator still requires a trusted trigger-label applier" do
    events = [labeled_event(10, "agent:todo", "outsider", "2026-01-01T00:00:00Z")]

    denied = authorize_with_events(issue(creator_login: "trusted"), events, ["trusted"])

    refute denied.dispatch_authorized?
    assert denied.dispatch_authorization == :denied
  end

  # Allowed-contributor intake (#2957) grants a wake, never dispatch authority.
  # These are guards: dispatch already ignores the creator, and they pin that
  # an allow-listed author can neither self-dispatch nor be dispatched by an
  # outsider's relabel — while a trusted applier dispatches their issue
  # exactly like an operator-filed one.
  describe "allowed-contributor issues (#2957)" do
    test "an allowed contributor labelling their own issue does not dispatch it" do
      events = [labeled_event(10, "agent:todo", "contributor", "2026-01-01T00:00:00Z")]
      denied = authorize_with_events(issue(creator_login: "contributor"), events, ["operator"])

      refute denied.dispatch_authorized?
      assert denied.dispatch_authorization == :denied
    end

    test "a non-allowed user labelling an allowed contributor's issue does not dispatch it" do
      events = [labeled_event(10, "agent:todo", "mallory", "2026-01-01T00:00:00Z")]
      denied = authorize_with_events(issue(creator_login: "contributor"), events, ["operator"])

      refute denied.dispatch_authorized?
    end

    test "a trusted applier dispatches an allowed contributor's issue like an operator-filed one" do
      events = [labeled_event(10, "agent:todo", "operator", "2026-01-01T00:00:00Z")]
      authorized = authorize_with_events(issue(creator_login: "contributor"), events, ["operator"])

      assert authorized.dispatch_authorized?
      assert authorized.dispatch_authorization == :authorized
    end
  end

  # The bot login has to be in `allowed_users` for the fleet to work at all, so
  # this is exactly what the creator short-circuit left unchecked: a ticket
  # filed with the bot credential dispatched on creator alone, whoever applied —
  # or did not apply — the trigger label.
  test "an agent-filed ticket does not dispatch on an outsider's label" do
    events = [labeled_event(10, "agent:todo", "outsider", "2026-01-01T00:00:00Z")]

    denied = authorize_with_events(issue(creator_login: "aiur-bot"), events, ["aiur-bot"])

    refute denied.dispatch_authorized?
  end

  # The trigger label is the issue's CURRENT state label, and Aiur moves that
  # label itself on every transition. Without the carry-forward, the first
  # `todo → in-progress` transition makes the verified applier the bot, the
  # issue reads unauthorized, and `Orchestrator.Reconciler` kills the running
  # agent. The old creator short-circuit hid this for operator-filed tickets.
  test "an Aiur state transition does not revoke a human-triaged ticket" do
    events = [
      labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z"),
      labeled_event(11, "agent:in-progress", "aiur-bot", "2026-01-02T00:00:00Z")
    ]

    authorized =
      authorize_with_events(issue(state: "in-progress"), events, ["trusted"], bot_account: "aiur-bot")

    assert authorized.dispatch_authorized?
    assert authorized.dispatch_authorization == :authorized
  end

  test "an Aiur state transition carries nothing forward when no trusted actor ever triaged" do
    events = [
      labeled_event(10, "agent:todo", "aiur-bot", "2026-01-01T00:00:00Z"),
      labeled_event(11, "agent:in-progress", "aiur-bot", "2026-01-02T00:00:00Z")
    ]

    denied =
      authorize_with_events(issue(state: "in-progress"), events, ["trusted"], bot_account: "aiur-bot")

    refute denied.dispatch_authorized?
    assert denied.dispatch_authorization == :denied
  end

  # Carry-forward is deliberately limited to Aiur's own identity. "Latest
  # applier wins" is what stops a hostile relabel riding a stale approval, so
  # any non-Aiur actor still replaces the decision.
  test "an outsider relabel still revokes even after a trusted triage" do
    events = [
      labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z"),
      labeled_event(11, "agent:in-progress", "outsider", "2026-01-02T00:00:00Z")
    ]

    denied =
      authorize_with_events(issue(state: "in-progress"), events, ["trusted"], bot_account: "aiur-bot")

    refute denied.dispatch_authorized?
  end

  # SPLIT IDENTITY — the state label above is written with the *daemon's*
  # credential, so under GitHub App auth the timeline actor is the App bot, not
  # the account agents publish under. Every carry-forward test above uses one
  # login for both roles, which is the blind spot that let the original
  # conflation hide: with a single identity, matching the wrong one still
  # matches. Here the two logins differ, so only a union answers correctly.
  # Getting this wrong denies authorization on each ticket's first transition
  # and `Orchestrator.Reconciler` kills the running agent.
  test "SPLIT IDENTITY: a daemon App-bot state transition does not revoke a human-triaged ticket" do
    events = [
      labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z"),
      labeled_event(11, "agent:in-progress", "aiur-daemon[bot]", "2026-01-02T00:00:00Z")
    ]

    authorized =
      authorize_with_events(issue(state: "in-progress"), events, ["trusted"],
        bot_account: "its-applekid",
        daemon_account: "aiur-daemon[bot]"
      )

    assert authorized.dispatch_authorized?
  end

  # The other half of the union: an agent moving a label with its own
  # credential appears as the bot account, and that must carry forward too.
  test "SPLIT IDENTITY: an agent-applied state label also carries the triage decision forward" do
    events = [
      labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z"),
      labeled_event(11, "agent:in-progress", "its-applekid", "2026-01-02T00:00:00Z")
    ]

    authorized =
      authorize_with_events(issue(state: "in-progress"), events, ["trusted"],
        bot_account: "its-applekid",
        daemon_account: "aiur-daemon[bot]"
      )

    assert authorized.dispatch_authorized?
  end

  # Widening to a union must not widen who counts as Aiur. A third party is
  # still a third party, and "latest applier wins" still revokes.
  test "SPLIT IDENTITY: an outsider relabel still revokes under a split identity" do
    events = [
      labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z"),
      labeled_event(11, "agent:in-progress", "its-everdred", "2026-01-02T00:00:00Z")
    ]

    denied =
      authorize_with_events(issue(state: "in-progress"), events, ["trusted"],
        bot_account: "its-applekid",
        daemon_account: "aiur-daemon[bot]"
      )

    refute denied.dispatch_authorized?
  end

  test "an agent-filed ticket with no trigger-label event at all is denied" do
    denied = authorize_with_events(issue(creator_login: "aiur-bot"), [], ["aiur-bot"])

    refute denied.dispatch_authorized?
  end

  test "an allowlisted creator is dispatched once the trigger label is verifiably theirs" do
    events = [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]

    authorized = authorize_with_events(issue(creator_login: "trusted"), events, ["trusted"])

    assert authorized.dispatch_authorized?
  end

  test "contradictory workflow state labels deny even a trusted creator and raise attention" do
    :ok = AgentPubSub.subscribe_agent("42")

    issue = issue(creator_login: "trusted", state: nil, state_labels: ["error", "todo"])

    denied =
      DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
        allowed_users: ["trusted"],
        request_fun: fn _request -> flunk("a contradiction must fail before timeline authorization") end
      )

    refute denied.dispatch_authorized?

    assert_receive {:alert,
                    %{
                      name: "github.dispatch_authorization.ambiguous",
                      reason: reason,
                      needs_attention: true
                    }},
                   2_000

    assert reason =~ "contradictory_state_labels"
    assert reason =~ "error"
    assert reason =~ "todo"
  end

  test "allows an outsider when the most recent trigger-label applier is trusted" do
    events = [
      labeled_event(10, "agent:todo", "outsider", "2026-01-01T00:00:00Z"),
      labeled_event(11, "agent:todo", "trusted", "2026-01-02T00:00:00Z")
    ]

    authorized = authorize_with_events(issue(), events, ["trusted"])

    assert authorized.dispatch_authorized?
  end

  test "denies an unlisted creator and unlisted trigger-label applier" do
    denied =
      authorize_with_events(
        issue(),
        [labeled_event(10, "agent:todo", "outsider", "2026-01-01T00:00:00Z")],
        ["trusted"]
      )

    refute denied.dispatch_authorized?
  end

  test "uses event id to break same-timestamp timeline ties" do
    events = [
      labeled_event(11, "agent:todo", "trusted", "2026-01-01T00:00:00Z"),
      labeled_event(12, "agent:todo", "outsider", "2026-01-01T00:00:00Z")
    ]

    refute authorize_with_events(issue(), events, ["trusted"]).dispatch_authorized?
  end

  test "follows timeline pages before deciding label provenance" do
    first_page = [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]
    second_page = [labeled_event(11, "agent:todo", "outsider", "2026-01-02T00:00:00Z")]

    request_fun = fn %{url: url} ->
      if String.contains?(url, "page=2") do
        {:ok, %{status: 200, headers: [], body: second_page}}
      else
        next = ~s(<https://api.github.com/repos/owner/repo/issues/42/timeline?per_page=100&page=2>; rel="next")
        {:ok, %{status: 200, headers: [{"link", next}], body: first_page}}
      end
    end

    refute DispatchAuthorization.authorize(issue(), "owner", "repo", "agent", allowed_users: ["trusted"], token: "test-token", request_fun: request_fun).dispatch_authorized?
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
    assert first.dispatch_authorization == :denied
    assert_receive {:timeline_poll, 0}

    # GitHub's read cache holds the endpoint snapshot until a webhook tells it
    # that the later label event has been indexed.
    ReadCache.reset()

    second =
      DispatchAuthorization.authorize(created_with_label, "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: request_fun
      )

    assert second.dispatch_authorized?
    assert second.dispatch_authorization == :authorized
    assert_receive {:timeline_poll, 1}
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

    assert_receive :unconditional

    assert DispatchAuthorization.authorize(issue(updated_at: ~U[2026-01-02 00:00:00Z]), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    assert_receive :conditional
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

    assert_receive :unconditional

    # The fingerprint moved; page 1 304s but reports a new page, so the held
    # single page cannot be trusted and the whole timeline is refetched.
    assert DispatchAuthorization.authorize(issue(updated_at: ~U[2026-01-02 00:00:00Z]), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    assert_receive :conditional
    assert_receive :unconditional
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

    deferred =
      DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: request_fun
      )

    refute deferred.dispatch_authorized?
    assert deferred.dispatch_authorization == :deferred

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

    deferred =
      DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: request_fun
      )

    refute deferred.dispatch_authorized?
    assert deferred.dispatch_authorization == :deferred
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

  test "fails closed when the timeline contains no matching trigger-label event" do
    denied = authorize_with_events(issue(), [labeled_event(10, "agent:rework", "trusted", "2026-01-01T00:00:00Z")], ["trusted"])

    refute denied.dispatch_authorized?
    assert denied.dispatch_authorization == :denied
  end

  test "missing or malformed current-label evidence still revokes active and rework tickets" do
    for state <- ["in-progress", "rework"] do
      current_label = "agent:#{state}"

      malformed_event = %{
        "event" => "labeled",
        "label" => %{"name" => current_label},
        "actor" => %{"login" => "outsider"}
      }

      for events <- [[], [malformed_event]] do
        denied = authorize_with_events(issue(state: state), events, ["trusted"])

        refute denied.dispatch_authorized?
        assert denied.dispatch_authorization == :denied
      end
    end
  end

  test "fails closed when the timeline request errors" do
    denied =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn _request -> {:error, :timeout} end
      )

    refute denied.dispatch_authorized?
  end

  test "fails closed when the timeline response is malformed" do
    denied =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn _request -> :malformed_response end
      )

    refute denied.dispatch_authorized?
  end

  # A truncated timeline body is an inability to fetch/parse, not a provenance
  # verdict: it *defers* (fail-closed, never revoked) instead of emitting an
  # ambiguous attention alert, and the underlying cause is the truncation, not
  # a self-contradictory `{:github, :http, %{status: 200}}` (#1454, #2409).
  test "a truncated 200 timeline body defers with :timeline_truncated, not an HTTP status error" do
    :ok = AgentPubSub.subscribe_agent("42")

    denied =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn _request ->
          # What Transport.bounded_response_collector/1 produces when a page
          # exceeds @max_timeline_response_bytes: a 200 whose body is cleared.
          {:ok, %{status: 200, body: "", private: %{aiur_response_too_large: true}}}
        end
      )

    refute denied.dispatch_authorized?
    assert denied.dispatch_authorization == :deferred

    refute_receive {:alert,
                    %{
                      name: "github.dispatch_authorization.ambiguous",
                      needs_attention: true
                    }},
                   500
  end

  test "authorizes from a full per_page=100 timeline page without truncation" do
    events =
      for id <- 1..100 do
        labeled_event(id, "agent:todo", "trusted", "2026-01-01T00:00:00Z")
      end

    authorized =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn _request -> {:ok, %{status: 200, body: events}} end
      )

    assert authorized.dispatch_authorized?
  end

  # The 512 KiB cap deferred a real ticket forever: the timeline endpoint embeds
  # the full source issue in every `cross-referenced` event, so a ticket
  # referenced 13 times measured 777 KiB for 51 events while a less-referenced
  # one in the same repo fetched in 158 KiB. The cap has to clear the realistic
  # ceiling for a heavily-referenced ticket, not just a full page of plain
  # events (#2749).
  test "requests a timeline page cap that holds a heavily cross-referenced timeline" do
    request_fun = fn request ->
      assert request.max_response_bytes >= 4 * 1024 * 1024
      {:ok, %{status: 200, body: [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]}}
    end

    assert DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?
  end

  # A page over the cap says "this page size does not fit", not "this ticket
  # cannot be authorized". Halving `per_page` halves the embedded payload, so
  # the fetch retries smaller instead of deferring — which is what turned a
  # transient size problem into a permanently undispatchable ticket.
  test "a page over the cap is refetched at a smaller per_page instead of deferring" do
    {:ok, attempts} = Agent.start_link(fn -> [] end)

    request_fun = fn %{url: url} ->
      per_page = per_page_of(url)
      Agent.update(attempts, &(&1 ++ [per_page]))

      if per_page == 100 do
        {:ok, %{status: 200, body: "", private: %{aiur_response_too_large: true}}}
      else
        {:ok, %{status: 200, body: [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]}}
      end
    end

    authorized =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: request_fun
      )

    assert authorized.dispatch_authorized?
    assert authorized.dispatch_authorization == :authorized
    assert Agent.get(attempts, & &1) == [100, 50]
  end

  test "an oversized page defers only after every smaller per_page was tried" do
    {:ok, attempts} = Agent.start_link(fn -> [] end)

    request_fun = fn %{url: url} ->
      Agent.update(attempts, &(&1 ++ [per_page_of(url)]))
      {:ok, %{status: 200, body: "", private: %{aiur_response_too_large: true}}}
    end

    deferred =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: request_fun
      )

    refute deferred.dispatch_authorized?
    assert deferred.dispatch_authorization == :deferred
    assert Agent.get(attempts, & &1) == [100, 50, 25, 20, 10, 5, 1]
  end

  # Shrinking `per_page` must not shrink the timeline the decision reads: the
  # provenance budget is a number of events, so a smaller page buys more
  # requests rather than a shorter, silently-wrong history.
  test "a smaller per_page is allowed proportionally more pages" do
    {:ok, pages} = Agent.start_link(fn -> 0 end)

    request_fun = fn %{url: url} ->
      if per_page_of(url) == 100 do
        {:ok, %{status: 200, body: "", private: %{aiur_response_too_large: true}}}
      else
        Agent.update(pages, &(&1 + 1))
        {:ok, %{status: 200, headers: [{"link", ~s(<#{url}&page=next>; rel="next")}], body: []}}
      end
    end

    denied =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: request_fun
      )

    refute denied.dispatch_authorized?
    # 400 events / per_page=50 = 8 pages, versus the 4 a per_page=100 fetch gets.
    assert Agent.get(pages, & &1) == 8
  end

  # The decision reads five fields per event and never the embedded `source`
  # issue the timeline attaches to every cross-reference. Holding those bodies
  # in the timeline cache made a well-documented ticket cost hundreds of KiB per
  # issue for evidence no decision consults.
  test "the cached timeline drops embedded cross-reference bodies" do
    cross_reference = %{
      "id" => 9,
      "event" => "cross-referenced",
      "created_at" => "2026-01-01T00:00:00Z",
      "actor" => %{"login" => "trusted"},
      "source" => %{"issue" => %{"body" => String.duplicate("x", 200_000)}}
    }

    events = [cross_reference, labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]

    authorized = authorize_with_events(issue(), events, ["trusted"])

    assert authorized.dispatch_authorized?

    [{"42", held}] = :ets.lookup(:aiur_github_dispatch_authorization_timelines, "42")

    refute Enum.any?(held.events, &Map.has_key?(&1, "source"))

    assert :erts_debug.flat_size(held.events) < :erts_debug.flat_size(events)
  end

  # Pruning must not change what the decision sees: the same timeline with and
  # without a multi-hundred-KB embedded source authorizes identically.
  test "an embedded source body does not change the authorization decision" do
    label_event = labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")

    bulky = [
      Map.put(label_event, "source", %{"issue" => %{"body" => String.duplicate("x", 300_000)}})
    ]

    DispatchAuthorization.clear_cache()
    lean = authorize_with_events(issue(), [label_event], ["trusted"])

    DispatchAuthorization.clear_cache()
    fat = authorize_with_events(issue(), bulky, ["trusted"])

    assert lean.dispatch_authorized?
    assert fat.dispatch_authorized? == lean.dispatch_authorized?
    assert fat.dispatch_authorization == lean.dispatch_authorization
  end

  # The deferral warning goes to `aiur.log` and nowhere else, so a ticket whose
  # timeline fetch keeps failing sat undispatched forever with nothing an
  # Executor reads. One deferral is routine; a streak is an operator problem.
  test "a repeated deferral raises one needs-attention alert naming the issue and reason" do
    :ok = AgentPubSub.subscribe_agent("42")

    defer_once = fn ->
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn _request -> {:error, :timeout} end
      )
    end

    for _cycle <- 1..4 do
      assert defer_once.().dispatch_authorization == :deferred
    end

    refute_receive {:alert, %{name: "ticket.42.agent.attention.dispatch_authorization.deferred"}}, 100

    assert defer_once.().dispatch_authorization == :deferred

    assert_receive {:alert,
                    %{
                      name: "ticket.42.agent.attention.dispatch_authorization.deferred",
                      needs_attention: true,
                      severity: "warning"
                    } = alert},
                   500

    assert alert.message =~ "42"
    assert alert.message =~ "timeout"

    # One alert per streak, not one per cycle.
    assert defer_once.().dispatch_authorization == :deferred
    refute_receive {:alert, %{name: "ticket.42.agent.attention.dispatch_authorization.deferred"}}, 100
  end

  test "an alerted deferral streak reports its recovery when the ticket authorizes" do
    :ok = AgentPubSub.subscribe_agent("42")

    for _cycle <- 1..5 do
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn _request -> {:error, :timeout} end
      )
    end

    assert_receive {:alert, %{name: "ticket.42.agent.attention.dispatch_authorization.deferred"}}, 500

    authorized =
      authorize_with_events(
        issue(),
        [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")],
        ["trusted"]
      )

    assert authorized.dispatch_authorized?

    assert_receive {:alert,
                    %{
                      name: "ticket.42.agent.attention.dispatch_authorization.deferred.resolved",
                      needs_attention: false
                    }},
                   500
  end

  test "two alerted issue streaks resolve independently and recovery can end in denial" do
    :ok = AgentPubSub.subscribe_agent("42")
    :ok = AgentPubSub.subscribe_agent("43")
    issue_a = issue(id: "42", identifier: "42")
    issue_b = issue(id: "43", identifier: "43")

    defer = fn ticket ->
      DispatchAuthorization.authorize(ticket, "owner", "repo", "agent", allowed_users: ["trusted"], token: "test-token", request_fun: fn _request -> {:error, :timeout} end)
    end

    for _cycle <- 1..5 do
      assert defer.(issue_a).dispatch_authorization == :deferred
      assert defer.(issue_b).dispatch_authorization == :deferred
    end

    assert_receive {:alert, %{name: "ticket.42.agent.attention.dispatch_authorization.deferred", needs_attention: true, source_ticket_id: "42"}}
    assert_receive {:alert, %{name: "ticket.43.agent.attention.dispatch_authorization.deferred", needs_attention: true, source_ticket_id: "43"}}

    deny = fn ticket ->
      DispatchAuthorization.authorize(ticket, "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn _request ->
          {:ok, %{status: 200, body: [labeled_event(10, "agent:todo", "outsider", "2026-01-01T00:00:00Z")]}}
        end
      )
    end

    refute deny.(issue_a).dispatch_authorized?
    assert_receive {:alert, %{name: "ticket.42.agent.attention.dispatch_authorization.deferred.resolved", needs_attention: false}}
    refute_receive {:alert, %{name: "ticket.43.agent.attention.dispatch_authorization.deferred"}}, 100

    refute deny.(issue_b).dispatch_authorized?
    assert_receive {:alert, %{name: "ticket.43.agent.attention.dispatch_authorization.deferred.resolved", needs_attention: false}}
    refute_receive {:alert, %{name: "ticket.42.agent.attention.dispatch_authorization.deferred.resolved"}}, 100
  end

  # No regression into noise: a single deferral is a rate limit or a blip, and
  # alerting on it would bury the streak that actually needs an operator.
  test "a single deferral does not alert" do
    :ok = AgentPubSub.subscribe_agent("42")

    deferred =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn _request -> {:error, :timeout} end
      )

    assert deferred.dispatch_authorization == :deferred
    refute_receive {:alert, %{name: "ticket.42.agent.attention.dispatch_authorization.deferred"}}, 200
  end

  # A streak that never reached the threshold has nothing to report recovering
  # from, so a ticket that deferred twice and then dispatched stays silent.
  test "an unalerted deferral streak reports no recovery" do
    :ok = AgentPubSub.subscribe_agent("42")

    for _cycle <- 1..2 do
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn _request -> {:error, :timeout} end
      )
    end

    authorized =
      authorize_with_events(
        issue(),
        [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")],
        ["trusted"]
      )

    assert authorized.dispatch_authorized?
    refute_receive {:alert, %{name: "ticket.42.agent.attention.dispatch_authorization.deferred.resolved"}}, 200
  end

  test "requests a timeline page cap that holds per_page=100 events" do
    # Measured real timelines run ~2.5-3.5 KiB per event; a full 100-event page
    # needs ~350 KiB, so the response cap must comfortably exceed 64 KiB.
    request_fun = fn request ->
      assert request.max_response_bytes >= 100 * 3_500
      {:ok, %{status: 200, body: [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]}}
    end

    assert DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?
  end

  test "fails closed when timeline pagination exceeds the provenance budget" do
    request_fun = fn %{url: url} ->
      next = "<#{url}&page=next>; rel=\"next\""
      {:ok, %{status: 200, headers: [{"link", next}], body: []}}
    end

    denied =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: request_fun
      )

    refute denied.dispatch_authorized?
  end

  test "accepts numeric timeline event ids encoded as strings" do
    authorized = authorize_with_events(issue(), [labeled_event("10", "agent:todo", "trusted", "2026-01-01T00:00:00Z")], ["trusted"])

    assert authorized.dispatch_authorized?
  end

  test "fails closed when the latest matching label event has no actor" do
    :ok = AgentPubSub.subscribe_agent("42")

    denied =
      authorize_with_events(
        issue(),
        [
          %{
            "id" => 10,
            "event" => "labeled",
            "label" => %{"name" => "agent:todo"},
            "created_at" => "2026-01-01T00:00:00Z"
          }
        ],
        ["trusted"]
      )

    refute denied.dispatch_authorized?

    assert_receive {:alert,
                    %{
                      name: "github.dispatch_authorization.ambiguous",
                      needs_attention: true,
                      severity: "warning"
                    }},
                   500
  end

  test "fails closed when a matching timeline event is malformed" do
    denied =
      authorize_with_events(
        issue(),
        [
          %{
            "id" => 10,
            "event" => "labeled",
            "label" => %{"name" => "agent:todo"},
            "actor" => %{"login" => "trusted"}
          }
        ],
        ["trusted"]
      )

    refute denied.dispatch_authorized?
    assert denied.dispatch_authorization == :denied
  end

  test "fails closed before timeline lookup when the issue has no trigger label" do
    denied =
      DispatchAuthorization.authorize(%{issue() | state: nil}, "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn _ -> flunk("unlabeled issue must not query the timeline") end
      )

    refute denied.dispatch_authorized?
  end

  # --- a timeline page bigger than the response cap (#1454 recurrence) ---
  #
  # Measured on aiur-team/khala#257 (2026-09-26): `per_page=100` page 1 was
  # 575,125 bytes, past the 524,288-byte cap, so the transport cleared the body
  # and the fetch reported `:timeline_truncated`. Because that is a hard limit hit
  # on EVERY fetch rather than a cache, the ticket could never be dispatched
  # again: not by relabelling from a trusted user, not after a daemon restart.
  # The operator had to close it and re-file. The same issue at `per_page=50` was
  # 262,218 bytes and at `per_page=20` was 93,723 bytes.
  #
  # `paged_timeline_request_fun/1` stands in for the real transport: it slices by
  # the `per_page` in the URL, emits `Link: rel="next"` while pages remain, and
  # answers any page whose encoded size exceeds the request's
  # `max_response_bytes` with the 200-plus-cleared-body that
  # `Transport.bounded_response_collector/1` produces.
  test "a timeline too big for per_page=100 still resolves its label applier" do
    events = fat_timeline(120, 100_000)

    authorized =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: paged_timeline_request_fun(events)
      )

    # The whole page-1 body at per_page=100 is past the cap, which is what denied
    # khala#257 forever.
    assert encoded_size(Enum.take(events, 100)) > 4_194_304
    assert encoded_size(Enum.take(events, 25)) < 4_194_304

    assert authorized.dispatch_authorized?
    assert authorized.dispatch_authorization == :authorized
  end

  # Fixes tickets that are ALREADY oversized, without changing the healthy path:
  # truncation at the default page size is a statement about the page, so the
  # timeline is refetched in smaller pages before the failure is believed.
  test "truncation at the default page size is retried at a smaller page size" do
    events = fat_timeline(60, 100_000)

    {:ok, sizes} = Agent.start_link(fn -> [] end)

    request_fun = paged_timeline_request_fun(events)

    authorized =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn %{url: url} = request ->
          Agent.update(sizes, &[query_value(url, "per_page") | &1])
          request_fun.(request)
        end
      )

    # Truncated at 50 events, recovered at 25 under the 4 MiB cap.
    assert encoded_size(Enum.take(events, 50)) > 4_194_304
    assert encoded_size(Enum.take(events, 25)) < 4_194_304

    assert authorized.dispatch_authorized?
    requested = sizes |> Agent.get(&Enum.reverse(&1)) |> Enum.uniq()
    assert requested == ["100", "50", "25"]
  end

  test "a large cross-reference event is recovered below per_page=20" do
    events = fat_timeline(21, 100_000)
    # Model one embedded source issue that makes a 25-event page too large,
    # while remaining readable in the 20-event page on page 2.
    events = List.replace_at(events, 20, fat_timeline(1, 3_000_000) |> hd())
    sizes = start_supervised!({Agent, fn -> [] end})
    request_fun = paged_timeline_request_fun(events)

    authorized =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn %{url: url} = request ->
          Agent.update(sizes, &[query_value(url, "per_page") | &1])
          request_fun.(request)
        end
      )

    assert authorized.dispatch_authorized?
    requested = sizes |> Agent.get(&Enum.reverse(&1)) |> Enum.uniq()
    assert "25" in requested
    assert "20" in requested
  end

  # The security invariant is untouched: when the evidence cannot be obtained at
  # ANY page size it is still fail-closed. What changes is that the refusal says
  # so — a transport limit is a different alert from an ambiguous provenance
  # verdict, and `cause=transport_limit` is in the log line (#2797).
  test "a timeline unreadable at every page size defers without a provenance denial" do
    :ok = AgentPubSub.subscribe_agent("42")

    events = fat_timeline(40, 1_000)
    events = List.replace_at(events, 0, fat_timeline(1, 5_000_000) |> hd())
    assert encoded_size(Enum.take(events, 1)) > 4_194_304

    deferred =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: paged_timeline_request_fun(events)
      )

    refute deferred.dispatch_authorized?
    assert deferred.dispatch_authorization == :deferred

    refute_receive {:alert, %{name: "github.dispatch_authorization.ambiguous"}}, 200
    refute_receive {:alert, %{name: "ticket.42.agent.attention.dispatch_authorization.deferred"}}, 200
  end

  defp fat_timeline(count, padding_bytes) do
    padding = String.duplicate("x", padding_bytes)

    for id <- 1..count do
      labeled_event(id, "agent:todo", "trusted", "2026-01-01T00:00:00Z")
      |> Map.put("body", padding)
    end
  end

  defp encoded_size(events), do: byte_size(Jason.encode!(events))

  defp query_value(url, key) do
    url
    |> URI.parse()
    |> Map.get(:query)
    |> Kernel.||("")
    |> URI.decode_query()
    |> Map.get(key)
  end

  defp paged_timeline_request_fun(events) do
    total = length(events)

    fn %{url: url} = request ->
      per_page = url |> query_value("per_page") |> String.to_integer()
      page = url |> query_value("page") |> page_number()
      slice = Enum.slice(events, (page - 1) * per_page, per_page)
      last_page = div(total + per_page - 1, per_page)
      headers = next_page_headers(page, last_page, per_page)

      if encoded_size(slice) > request.max_response_bytes do
        {:ok, %{status: 200, body: "", headers: headers, private: %{aiur_response_too_large: true}}}
      else
        {:ok, %{status: 200, body: slice, headers: headers}}
      end
    end
  end

  defp page_number(nil), do: 1
  defp page_number(value), do: String.to_integer(value)

  defp next_page_headers(page, last_page, per_page) when page < last_page do
    next = "https://api.github.com/repos/owner/repo/issues/42/timeline?per_page=#{per_page}&page=#{page + 1}"
    [{"link", "<#{next}>; rel=\"next\""}]
  end

  defp next_page_headers(_page, _last_page, _per_page), do: []

  defp authorize_with_events(issue, events, allowed_users, extra_opts \\ []) do
    DispatchAuthorization.authorize(
      issue,
      "owner",
      "repo",
      "agent",
      Keyword.merge(
        [
          allowed_users: allowed_users,
          token: "test-token",
          request_fun: fn _request -> {:ok, %{status: 200, body: events}} end
        ],
        extra_opts
      )
    )
  end

  defp issue(attrs \\ []) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: "42",
          identifier: "42",
          title: "Issue",
          state: "todo",
          creator_login: "outsider",
          dispatch_revision: "\"issue-42-v1\"",
          updated_at: ~U[2026-01-01 00:00:00Z]
        ],
        attrs
      )
    )
  end

  defp per_page_of(url) do
    [_all, per_page] = Regex.run(~r/per_page=(\d+)/, url)
    String.to_integer(per_page)
  end

  defp labeled_event(id, label, actor, created_at) do
    %{
      "id" => id,
      "event" => "labeled",
      "label" => %{"name" => label},
      "actor" => %{"login" => actor},
      "created_at" => created_at
    }
  end
end
