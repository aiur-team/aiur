defmodule AiurWeb.BuildOrderLive.FaultsTest do
  use AiurWeb.BuildOrderLiveCase

  test "coalesces source invalidation bursts behind one in-flight cached read" do
    parent = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    loader = fn ->
      call = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)
      send(parent, {:source_load_started, call, self()})

      receive do
        {:release_sources, ^call} ->
          %{
            execution: %{running: [], retrying: [], idle: []},
            activity: %{generation: call, entries: []}
          }
      end
    end

    _source = install_source(catalog: catalog_snapshot([], 1, :healthy), sources_loader: loader)
    assert {:ok, view, _html} = live(build_conn(), "/build-orders")
    assert_receive {:source_load_started, 1, first_loader}, 2_000

    send(view.pid, {:ticket_activity_changed, %{generation: 2}})
    send(view.pid, {:running_changed, []})
    send(first_loader, {:release_sources, 1})
    assert_receive {:source_load_started, 2, second_loader}, 2_000
    refute_receive {:source_load_started, 3, _loader}, 100

    send(second_loader, {:release_sources, 2})
    render_async(view, 2_000)
    refute_receive {:source_load_started, 3, _loader}, 100
  end

  test "patching between roots releases the old scope before activating the new one", %{
    source: source,
    first: first,
    second: second
  } do
    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    html = render_patch(view, "/build-orders/43")

    assert html =~ ~s(data-build-order-root="43")
    assert html =~ "Build Order #43"

    calls = FakeDataSource.calls(source)
    release_index = call_index(calls, {:release, [first]})
    unsubscribe_index = call_index(calls, {:unsubscribe_selected, [first]})
    subscribe_index = call_index(calls, {:subscribe_selected, [second]})
    demand_index = call_index(calls, {:demand, [second]})

    assert release_index < unsubscribe_index
    assert unsubscribe_index < subscribe_index
    assert subscribe_index < demand_index
  end

  test "selected publications reject the wrong root and accept one newer generation", %{
    first: first,
    second: second
  } do
    {:ok, view, html} = live(build_conn(), "/build-orders/42")
    assert html =~ "Valid empty graph"

    send(
      view.pid,
      {:graph_projection_generation, selected_snapshot(second, "Wrong delayed root", 99, :healthy, members: [member(98)])}
    )

    refute render(view) =~ "Ticket 98"

    send(
      view.pid,
      {:graph_projection_generation, selected_snapshot(first, "Root forty-two updated", 2, :healthy, members: [member(99)])}
    )

    assert render(view) =~ "Ticket 99"

    send(
      view.pid,
      {:graph_projection_health, selected_snapshot(first, nil, 2, :stale, refreshing?: true)}
    )

    health_html = render(view)
    assert health_html =~ ~s(data-build-order-status="selected_stale")
    assert health_html =~ "Ticket 99"
    # Degraded provider states surface as an explicit state card (the always-on
    # health badge was removed from the header).
    assert health_html =~ "Showing the last saved plan."
  end

  test "collapses structurally invalid selected data into one copyable page-level state", %{
    first: first
  } do
    {:ok, view, _html} = live(build_conn(), "/build-orders/42")

    invalid = SelectedRoot.new(RootSummary.new(%{}), [], health(2, :healthy))
    send(view.pid, {:graph_projection_generation, selected_snapshot(first, invalid, 2, :healthy)})

    html = render(view)
    {:ok, document} = Floki.parse_document(html)

    assert html =~ ~s(data-build-order-status="selected_invalid")
    assert [_card] = Floki.find(document, ".bo-state-card")
    assert html =~ "The plan is unreadable"
    assert html =~ "Investigate why Build Order #42&#39;s plan is unreadable."
    assert html =~ "`members: 0`"
    assert html =~ "`invalid_root`"
    refute html =~ "Build Order graph summary"
    refute html =~ "Plan distribution is unreadable"
    refute html =~ "Analytics unavailable"
    refute html =~ "Usage and cost unavailable"
    refute html =~ "Root data is unavailable."
  end

  # A producer that fails closed on a structural defect marks provider health
  # failed too. Sourcing the reported fault from health rendered one confident
  # card that blamed `rate_limited` for a malformed graph — a card count of 1 is
  # no better than six if the one card names the wrong reason.
  test "names the structural fault, not the fail-closed provider health failure", %{first: first} do
    {:ok, view, _html} = live(build_conn(), "/build-orders/42")

    invalid = SelectedRoot.new(root(first, "Malformed planning graph"), [:not_a_member], health(2, :unavailable, failure: :rate_limited))

    send(
      view.pid,
      {:graph_projection_generation, selected_snapshot(first, invalid, 2, :unavailable, failure: :rate_limited)}
    )

    html = render(view)
    {:ok, document} = Floki.parse_document(html)

    assert [card] = Floki.find(document, ".bo-state-card")
    card_text = Floki.text(card)

    assert html =~ ~s(data-build-order-status="selected_invalid")
    assert card_text =~ "The plan is unreadable"
    assert card_text =~ "Reported fault: invalid_member"
    assert html =~ "The selected-root provider reports `invalid_member`"
    refute card_text =~ "rate_limited"
  end

  test "rejects a delayed context completion after close", %{first: first} do
    parent = self()

    loader = fn identity ->
      send(parent, {:context_load_started, self(), identity})

      receive do
        :release_context -> %{detail: {:error, :unavailable}, history: {:error, :unavailable}}
      end
    end

    selected = selected_snapshot(first, "Root forty-two", 1, :healthy, members: [member(7)])

    source =
      install_source(
        catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
        selected: [selected],
        context_loader: loader
      )

    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    view |> element(~s([phx-click="open-ticket-context"])) |> render_click()

    assert_receive {:context_load_started, loader_pid, selected_identity}, 2_000
    assert selected_identity.identifier == "7"
    assert has_element?(view, ~s([role="dialog"]))

    view |> element(~s(button[phx-click="build-order-context-close"])) |> render_click()
    refute has_element?(view, ~s([role="dialog"]))

    send(loader_pid, :release_context)
    render_async(view, 2_000)
    refute has_element?(view, ~s([role="dialog"]))

    calls = FakeDataSource.calls(source)
    assert {:subscribe_context, [selected_identity]} in calls
    assert {:load_context, [selected_identity]} in calls
    assert {:unsubscribe_context, [selected_identity]} in calls
  end

  test "root switch closes old context scope and rejects its delayed completion", %{
    first: first,
    second: second
  } do
    parent = self()

    loader = fn identity ->
      send(parent, {:context_load_started, self(), identity})

      receive do
        :release_context -> context_result(identity, "Delayed old-root context")
      end
    end

    first_snapshot = selected_snapshot(first, "Root forty-two", 1, :healthy, members: [member(7)])

    second_snapshot =
      selected_snapshot(second, "Root forty-three", 1, :healthy, members: [member(8)])

    source =
      install_source(
        catalog:
          catalog_snapshot(
            [root(first, "Root forty-two"), root(second, "Root forty-three")],
            1,
            :healthy
          ),
        selected: [first_snapshot, second_snapshot],
        context_loader: loader
      )

    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    view |> element(~s([phx-click="open-ticket-context"])) |> render_click()
    assert_receive {:context_load_started, loader_pid, old_context_identity}, 2_000

    html = render_patch(view, "/build-orders/43")
    assert html =~ ~s(data-build-order-root="43")
    refute has_element?(view, ~s([role="dialog"]))
    assert {:unsubscribe_context, [old_context_identity]} in FakeDataSource.calls(source)

    send(loader_pid, :release_context)
    render_async(view, 2_000)
    refute render(view) =~ "Delayed old-root context"
    refute has_element?(view, ~s([role="dialog"]))
  end

  test "rotates context identity and coalesces an invalidation behind an in-flight read", %{
    first: first
  } do
    parent = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    loader = fn identity ->
      call = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)
      send(parent, {:context_load_started, call, self(), identity})

      receive do
        {:release_context, ^call} -> context_result(identity, "Context version #{call}")
      end
    end

    selected = selected_snapshot(first, "Root forty-two", 1, :healthy, members: [member(7)])

    source =
      install_source(
        catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
        selected: [selected],
        context_loader: loader
      )

    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    view |> element(~s([phx-click="open-ticket-context"])) |> render_click()

    assert_receive {:context_load_started, 1, first_loader, selected_identity}, 2_000
    send(view.pid, {:ticket_detail_updated, %{identity: selected_identity}})
    send(first_loader, {:release_context, 1})

    assert_receive {:context_load_started, 2, second_loader, ^selected_identity}, 2_000
    refute render(view) =~ "Context version 1"
    send(second_loader, {:release_context, 2})
    render_async(view, 2_000)
    assert render(view) =~ "Context version 2"

    assert Enum.count(
             FakeDataSource.calls(source),
             &match?({:load_context, [^selected_identity]}, &1)
           ) == 2
  end

  test "ignores cache publications for a different open identity", %{first: first} do
    selected = selected_snapshot(first, "Root forty-two", 1, :healthy, members: [member(7)])

    source =
      install_source(
        catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
        selected: [selected]
      )

    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    view |> element(~s([phx-click="open-ticket-context"])) |> render_click()
    render_async(view, 2_000)
    calls_before = FakeDataSource.calls(source)

    send(view.pid, {:ticket_detail_updated, %{identity: identity(99, "NODE-99")}})
    _ = render(view)
    assert FakeDataSource.calls(source) == calls_before
  end

  test "member context links running and paused chat but leaves completed and unstarted chat unavailable", %{first: first} do
    completed = %{member(9) | lifecycle: Lifecycle.from_github("CLOSED", "COMPLETED")}
    draft = %{member(10) | draft?: true}
    selected = selected_snapshot(first, "Root forty-two", 1, :healthy, members: [member(7), member(8), completed, draft])
    handles = Map.new(7..8, fn number -> {number, "conversation:" <> String.duplicate(Integer.to_string(number), 43)} end)

    install_source(
      catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
      selected: [selected],
      sources_loader: fn ->
        %{
          execution: %{
            running: [
              %{tracker_identity: identity(7, "NODE-7"), work_state: :working, live_conversation: %{generation_handle: handles[7]}},
              %{tracker_identity: identity(8, "NODE-8"), work_state: :paused, tracker_paused: true, live_conversation: %{generation_handle: handles[8]}}
            ],
            retrying: [],
            # StatusReport.idle_issue_snapshot/6 carries no conversation handle
            # after the worker leaves the running bucket.
            idle: [%{tracker_identity: identity(9, "NODE-9"), work_state: :idle}]
          },
          activity: %{generation: 1, entries: []}
        }
      end
    )

    endpoint_config =
      Keyword.put(Application.get_env(:aiur, Endpoint), :live_conversation_resolve_fun, fn handle ->
        case Enum.find(handles, fn {_number, candidate} -> candidate == handle end) do
          {7, _handle} -> {:ok, %{state: :live, messages: [%{content: "Current conversation"}]}}
          {8, _handle} -> {:ok, %{state: :stale, messages: [%{content: "Paused conversation"}]}}
          nil -> {:error, :unavailable}
        end
      end)

    Application.put_env(:aiur, Endpoint, endpoint_config)
    :ok = Endpoint.config_change([{Endpoint, endpoint_config}], [])

    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    render_async(view, 2_000)
    assert render(view) =~ "Estimated work progress"

    for number <- 7..8 do
      view |> element(~s([data-bo-card="#{number}"][phx-click="open-ticket-context"])) |> render_click()
      html = render(view)
      assert html =~ ~s(href="/chat/owner/repo/#{number}")
      assert html =~ "Read chat"
      view |> element(~s(button[phx-click="build-order-context-close"])) |> render_click()
    end

    view |> element(~s([data-bo-card="9"][phx-click="open-ticket-context"])) |> render_click()
    html = render(view)
    refute html =~ ~s(href="/chat/owner/repo/9")
    assert html =~ "Chat is unavailable."
    view |> element(~s(button[phx-click="build-order-context-close"])) |> render_click()

    view |> element(~s([data-bo-card="10"][phx-click="open-ticket-context"])) |> render_click()
    html = render(view)
    refute html =~ ~s(href="/chat/owner/repo/10")
    assert html =~ "Chat has not started for this ticket."
  end

  test "releases the selected demand and context subscriptions on termination", %{first: first} do
    selected = selected_snapshot(first, "Root forty-two", 1, :healthy, members: [member(7)])

    source =
      install_source(
        catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
        selected: [selected]
      )

    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    view |> element(~s([phx-click="open-ticket-context"])) |> render_click()
    render_async(view, 2_000)
    selected_identity = identity(7, "NODE-7")
    GenServer.stop(view.pid)

    calls = FakeDataSource.calls(source)
    assert {:release, [first]} in calls
    assert {:unsubscribe_selected, [first]} in calls
    assert {:unsubscribe_context, [selected_identity]} in calls
  end

  defp context_result(identity, title) do
    observed_at = ~U[2026-07-17 12:00:00Z]

    detail = %State{
      identity: identity,
      generation: 1,
      health: :healthy,
      detail: %DetailSnapshot{
        identity: identity,
        title: title,
        description: "Cached context",
        lifecycle: Lifecycle.from_github("OPEN", nil),
        url: "https://github.com/owner/repo/issues/#{identity.identifier}",
        created_at: observed_at,
        updated_at: observed_at,
        observed_at: observed_at
      },
      last_success_at: observed_at,
      last_attempt_at: observed_at
    }

    history = %TicketHistory.Snapshot{
      identity: identity,
      generation: 1,
      health: :available,
      status_label: "Current activity",
      progress: %{status: :unknown},
      latest_evidence: %{status: :unknown},
      entries: [],
      truncated?: false,
      observed_at: observed_at,
      freshness: :fresh,
      source_health: %{activity: :available, history: :available}
    }

    %{detail: {:ok, detail}, history: {:ok, history}}
  end
end
