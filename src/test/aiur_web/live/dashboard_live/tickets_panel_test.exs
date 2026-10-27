defmodule AiurWeb.DashboardLive.TicketsPanelTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.Processes
  import AiurWeb.DashboardLiveSupport.UnitFixtures

  alias Aiur.TestSupport.LiveViewAsync
  alias AiurWeb.OperatorControlCenter.AgentRoutingPreview

  @endpoint AiurWeb.Endpoint

  test "the Tickets panel lists open tickets and opens detail and add-agent modals" do
    # Pin the routing table to an entry that names a backend but no model. That is
    # the case the modal used to get wrong: the requested model is nil, so the
    # select fell back to "Backend default" while the table's routing column named
    # the model that would really run. A bare test daemon routes to a backend with
    # no default at all, which would make the prefill assertions vacuous.
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), agent_routing: %{5 => "kimi"})

    identity = units_identity()
    orchestrator_name = Module.concat(__MODULE__, :TicketsPanelOrchestrator)
    test_pid = self()
    orchestrator = start_counting_orchestrator(orchestrator_name, report: test_pid)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      open_tickets_fun: fn -> open_ticket_snapshot([open_ticket("2101", ["complexity:5"])]) end,
      add_agent_verify_fun: fn _ -> {:ok, [%{dispatch_authorization: :authorized, state: "todo"}]} end,
      add_agent_fun: fn identifier, label, action ->
        send(test_pid, {action, identifier, label})
        :ok
      end
    )

    {:ok, view, html} = live(build_conn(), "/units")

    assert html =~ "Tickets"
    assert html =~ "Unrouted backlog ticket"
    refute html =~ "ticket-detail-modal"

    view |> element(~s(td.tk-title-cell[phx-click="inspect-ticket"])) |> render_click()
    assert render(view) =~ "ticket-detail-modal"

    view
    |> element(~s(#ticket-detail-modal button[phx-click="close-ticket-detail"]))
    |> render_click()

    refute render(view) =~ "ticket-detail-modal"

    view |> element(~s(button[phx-click="open-add-agent"])) |> render_click()
    add_agent = render(view)

    # Prefilled from the routing table plus the ticket's own complexity tag. The
    # model select opens on the model the dispatcher would resolve — the value the
    # Tickets table used to print in a "Would route to" column. The expectation is
    # read from the preview rather than hard-coded because the routing table is
    # operator configuration and differs between environments.
    routing = AgentRoutingPreview.preview(["complexity:5"])

    assert routing.resolved_model in AgentRoutingPreview.options(routing.backend).models,
           "the routed model has to be one the modal can offer, or there is nothing to preselect"

    assert add_agent =~ "add-agent-modal"
    assert add_agent =~ "complexity:5"
    assert selected_option(add_agent, "backend") == routing.backend
    assert selected_option(add_agent, "model") == routing.resolved_model
    assert selected_option(add_agent, "complexity") == "5"

    # The routing explainer was deleted; the prefilling behaviour it described stays.
    # The column is refuted by its cell class, not by its header text: the ticket
    # detail modal still renders "Would route to" as a fact, and that is correct.
    refute add_agent =~ "Prefilled from the current routing configuration"
    refute add_agent =~ "tk-agent-cell"

    # Change the prefilled complexity before confirming, as an operator would.
    view |> element(~s(#add-agent-modal form)) |> render_change(%{"complexity" => "3"})
    view |> element(~s(#add-agent-modal form)) |> render_submit(%{})

    LiveViewAsync.render_when_complete(view)

    # The active-state label is what makes the ticket dispatchable at all, and the
    # complexity tag it replaces is removed rather than left to outrank it. The
    # model label carries the prefilled model, so the value the operator was shown
    # is the value written to the tracker rather than one re-derived later.
    model_label = "model:#{routing.backend}-#{routing.resolved_model}"

    assert_received {:add_label, "2101", "agent:todo"}
    assert_received {:add_label, "2101", "complexity:3"}
    assert_received {:add_label, "2101", ^model_label}
    assert_received {:remove_label, "2101", "complexity:5"}
    assert_received {:dashboard_refresh_requested, ^orchestrator}
    refute has_element?(view, "#add-agent-modal")
    assert render(view) =~ "Waiting for an agent to start"
  end

  test "read-only Tickets prevents opening the setup dialog even for a forged event" do
    start_test_endpoint(
      control_center_cache: false,
      dashboard_writable: false,
      open_tickets_fun: fn -> open_ticket_snapshot([open_ticket("2101", [])]) end
    )

    {:ok, view, html} = live(build_conn(), "/units")
    assert html =~ "Read-only dashboard: adding an agent is unavailable here"
    assert has_element?(view, ~s(button[id^="ticket-add-agent-"][disabled]))
    refute has_element?(view, ~s(button[phx-click="open-add-agent"]))

    [_, token] = Regex.run(~r/id="ticket-add-agent-([^"]+)"/, html)
    render_hook(view, "open-add-agent", %{"ticket" => token})
    refute has_element?(view, "#add-agent-modal")
  end

  test "the Tickets panel reveals the next batch on request and retires the control when exhausted" do
    identity = units_identity()
    orchestrator_name = Module.concat(__MODULE__, :TicketsRevealOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    # Enough tickets that exhausting the panel takes more than one reveal, so
    # the assign is shown to accumulate rather than jump straight to the end.
    tickets = Enum.map(1..20, &open_ticket("21#{String.pad_leading(to_string(&1), 2, "0")}", []))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      open_tickets_fun: fn -> open_ticket_snapshot(tickets) end
    )

    {:ok, view, html} = live(build_conn(), "/units")

    # The header keeps the total; the control names only the step it reveals.
    assert html =~ "20 tickets"
    assert ticket_row_count(html) == 5
    assert html =~ "Show 10 more tickets"

    revealed = reveal_more_tickets(view)

    # Progressive reveal: the first five stay put and the next batch joins them.
    assert ticket_row_count(revealed) == 15
    assert revealed =~ "Show 5 more tickets"

    exhausted = reveal_more_tickets(view)

    assert ticket_row_count(exhausted) == 20
    refute exhausted =~ "show-more-tickets"
  end

  test "the Tickets panel search filters the whole backlog and clears back to it" do
    identity = units_identity()
    orchestrator_name = Module.concat(__MODULE__, :TicketsSearchOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    tickets = [
      open_ticket("2101", []),
      open_ticket("2102", [],
        title: "Retry the dispatch",
        body_excerpt: "A storm of webhooks overwhelms the poller."
      ),
      open_ticket("2103", [], title: "Documentation refresh")
    ]

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      open_tickets_fun: fn -> open_ticket_snapshot(tickets) end
    )

    {:ok, view, html} = live(build_conn(), "/units")

    assert html =~ "3 tickets"

    # One term from the title and one from the body, in the other order: the
    # filter is tokenised, not a substring test against a single field.
    filtered = view |> element("form.tk-search") |> render_change(%{"query" => "storm retry"})

    assert filtered =~ "Retry the dispatch"
    refute filtered =~ "Documentation refresh"
    assert filtered =~ "1 of 3 tickets"

    empty = view |> element("form.tk-search") |> render_change(%{"query" => "zzzzqqqq"})

    assert empty =~ "No tickets match"
    refute empty =~ "tickets-rows"

    restored = view |> element("button.tk-search-clear") |> render_click()

    assert restored =~ "Documentation refresh"
    assert restored =~ ~s(<span class="rs-group-count">3 tickets</span>)
  end

  # The two features have to compose: a filter that only saw the revealed batch
  # would report a ticket as absent when it is merely still hidden, and a reveal
  # control counting the whole backlog would offer to reveal rows the query
  # excluded.

  test "the Tickets panel search reaches unrevealed tickets and the reveal control counts the matches" do
    identity = units_identity()
    orchestrator_name = Module.concat(__MODULE__, :TicketsSearchRevealOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    # Newest first, so #2101 sorts last — well past the opening batch of five.
    tickets =
      Enum.map(2..20, &open_ticket("21#{String.pad_leading(to_string(&1), 2, "0")}", [])) ++
        [open_ticket("2101", [], title: "Retry the dispatch")]

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      open_tickets_fun: fn -> open_ticket_snapshot(tickets) end
    )

    {:ok, view, html} = live(build_conn(), "/units")

    assert ticket_row_count(html) == 5
    refute html =~ "Retry the dispatch"

    filtered = view |> element("form.tk-search") |> render_change(%{"query" => "retry"})

    # Found although it was never rendered, and the reveal control is gone
    # because one match does not fill the opening batch.
    assert filtered =~ "Retry the dispatch"
    assert ticket_row_count(filtered) == 1
    assert filtered =~ "1 of 20 tickets"
    refute filtered =~ "show-more-tickets"

    # A broad query keeps the control, and it counts what the query matched —
    # the 19 default titles, not the 20 tickets behind them.
    broad = view |> element("form.tk-search") |> render_change(%{"query" => "backlog"})

    assert ticket_row_count(broad) == 5
    assert broad =~ "Show 10 more tickets"
    assert broad =~ "19 of 20 tickets"
  end

  test "an unavailable ticket listing is named rather than shown as zero tickets" do
    identity = units_identity()
    orchestrator_name = Module.concat(__MODULE__, :TicketsUnavailableOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      open_tickets_fun: fn -> raise "tracker unavailable" end
    )

    {:ok, _view, html} = live(build_conn(), "/units")

    assert html =~ "Open tickets are unavailable."
    assert html =~ "tickets unavailable"
    refute html =~ "0 tickets"
  end
end
