defmodule AiurWeb.DashboardLive.TicketContextTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.Processes
  import AiurWeb.DashboardLiveSupport.UnitFixtures

  alias Aiur.TestSupport.LiveViewAsync
  alias AiurWeb.OperatorControlCenter.UnitsPresenter

  @endpoint AiurWeb.Endpoint

  test "round-trips validated Units URL state and exposes a named zero-result reset" do
    identity = units_identity()
    membership = units_membership(identity)
    orchestrator_name = Module.concat(__MODULE__, :UnitsURLOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end
    )

    # The compact filter bar exposes a single `unfinished` scope toggle plus the
    # bulk All/None controls; scope/condition state still round-trips through the
    # URL exactly as before.
    {:ok, view, html} = live(build_conn(), "/units?v=1&scope=unfinished&conditions=active")

    assert html =~ "Responsive Units interface"
    assert has_element?(view, ~s(button[phx-value-scope="unfinished"][aria-pressed="true"]))
    assert has_element?(view, ~s(button[phx-value-condition="active"][aria-pressed="true"]))

    view
    |> element(~s(button[phx-value-condition="paused"]))
    |> render_click()

    assert_patch(view, "/units?v=1&scope=unfinished&conditions=active%2Cpaused")
    assert has_element?(view, ~s(button[phx-value-condition="active"][aria-pressed="true"]))
    assert has_element?(view, ~s(button[phx-value-condition="paused"][aria-pressed="true"]))

    # Bulk "None" clears scope + conditions to the empty selection, which yields
    # zero rows and surfaces the named reset affordance.
    view
    |> element(~s(button[phx-click="select-no-units-filters"]))
    |> render_click()

    assert_patch(view, "/units?v=1&scope=none")
    assert has_element?(view, ~s(button[phx-click="reset-units-filters"]), "Reset Units filters")

    view
    |> element(~s(button[phx-click="reset-units-filters"]))
    |> render_click()

    assert_patch(view, "/units?v=1")
    refute has_element?(view, ~s(button[phx-value-scope="unfinished"][aria-pressed="true"]))
    assert has_element?(view, "#units-rows .units-row")

    invalid_html = render_patch(view, "/units?v=999&scope=none&conditions=finished")
    assert invalid_html =~ "Responsive Units interface"
    assert_patch(view, "/units?v=1")
    refute has_element?(view, ~s(button[phx-value-scope="unfinished"][aria-pressed="true"]))
    refute has_element?(view, ~s(button[phx-value-condition="finished"][aria-pressed="true"]))

    render_hook(view, "table-sort-changed", %{"sort" => "units:latest:desc"})

    view
    |> element(~s(button[phx-value-condition="active"]))
    |> render_click()

    assert_patch(view, "/units?v=1&conditions=active&sort=units%3Alatest%3Adesc")

    render_patch(view, "/units?v=1&sort=units%3Acommand%3Adesc")
    assert_patch(view, "/units?v=1")
  end

  test "keeps valid Units selection and stable typed row identity across catalog updates" do
    identity = units_identity()
    {:ok, membership} = Agent.start_link(fn -> units_membership(identity) end)
    {:ok, activity} = Agent.start_link(fn -> units_activity(identity) end)
    orchestrator_name = Module.concat(__MODULE__, :UnitsUpdateOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> Agent.get(membership, & &1) end,
      units_activity_fun: fn -> Agent.get(activity, & &1) end
    )

    {:ok, view, _html} = live(build_conn(), "/units?v=1&scope=all")
    initial_document = view |> render() |> Floki.parse_document!()
    [row_id] = Floki.attribute(initial_document, ".units-row", "id")
    initial_announcement = initial_document |> Floki.find("#units-status") |> Floki.text()

    Agent.update(membership, fn snapshot ->
      member = snapshot.members |> hd() |> Map.merge(%{lifecycle: :terminal, terminal?: true})
      %{snapshot | generation: 2, members: [member]}
    end)

    Agent.update(activity, fn snapshot ->
      entry = snapshot.entries |> hd() |> put_in([:progress, :percent], 75)
      %{snapshot | generation: 2, entries: [entry]}
    end)

    send(view.pid, {:current_run_membership_changed, %{generation: 2}})
    send(view.pid, {:ticket_activity_changed, %{generation: 2}})
    send(view.pid, :reload_payload)
    _state = :sys.get_state(view.pid)

    # `all` scope has no dedicated button in the compact filter bar, but the
    # URL-provided selection persists across catalog updates — proven by the
    # now-terminal row (visible only under `scope=all`) remaining present with
    # its stable typed identity.
    assert has_element?(view, "##{row_id}")
    updated_html = render(view)
    assert has_element?(view, "##{row_id} .ut-pbar")
    assert has_element?(view, "##{row_id}", "75%")

    updated_announcement = updated_html |> Floki.parse_document!() |> Floki.find("#units-status") |> Floki.text()
    refute updated_announcement == initial_announcement
    assert updated_announcement =~ ~r/Update [a-f0-9]{10}/
  end

  test "opens shared ticket context only after explicit inspection and gates updates by typed identity" do
    identity = units_identity()
    membership = units_membership(identity)
    orchestrator_name = Module.concat(__MODULE__, :UnitsContextOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()
    {:ok, subscription_attempts} = Agent.start_link(fn -> 0 end)
    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      ticket_context_reset_subscribe_fun: fn ->
        send(test_pid, :ticket_context_resets_subscribed)
        Phoenix.PubSub.subscribe(Aiur.PubSub, "context-reset-3890")
      end,
      ticket_detail_subscribe_fun: fn selected ->
        attempt = Agent.get_and_update(subscription_attempts, fn current -> {current + 1, current + 1} end)
        send(test_pid, {:detail_subscribed, selected, attempt})
        if attempt == 1, do: {:error, :temporarily_unavailable}, else: :ok
      end,
      ticket_history_subscribe_fun: fn selected ->
        send(test_pid, {:history_subscribed, selected})
        :ok
      end,
      ticket_detail_unsubscribe_fun: fn selected ->
        send(test_pid, {:detail_unsubscribed, selected})
        :ok
      end,
      ticket_history_unsubscribe_fun: fn selected ->
        send(test_pid, {:history_unsubscribed, selected})
        :ok
      end,
      ticket_detail_request_fun: fn selected ->
        send(test_pid, {:detail_requested, selected})
        {:ok, units_ticket_detail(selected, "Responsive Units interface")}
      end,
      ticket_history_request_fun: fn selected ->
        send(test_pid, {:history_requested, selected})
        {:ok, units_ticket_history(selected)}
      end
    )

    {:ok, view, html} = live(build_conn(), "/units")
    assert_receive :ticket_context_resets_subscribed, 1000
    refute_receive :ticket_context_resets_subscribed, 100
    assert html =~ "Responsive Units interface"
    refute html =~ "units-ticket-context"
    refute_receive {:detail_requested, _identity}, 100
    refute_receive {:history_requested, _identity}, 100
    html = view |> element(~s(td.ut-id-cell[phx-click="inspect-unit"])) |> render_click()

    assert_receive {:detail_subscribed, ^identity, 1}, 1000
    assert_receive {:history_subscribed, ^identity}, 1000
    assert_receive {:detail_requested, ^identity}, 1000
    assert_receive {:history_requested, ^identity}, 1000
    assert html =~ ~s(id="units-ticket-context")
    assert html =~ "Ticket context"
    assert html =~ "Responsive Units interface"
    assert html =~ "Open in GitHub"
    assert html =~ "Chat is unavailable"
    assert html =~ "Commands"
    refute html =~ "/private/workspace"
    other = units_identity(provider_id: "NODE-other", identifier: "1111")
    send(view.pid, {:ticket_detail_updated, units_ticket_detail(other, "Wrong ticket")})
    refute render(view) =~ "Wrong ticket"

    send(view.pid, {:ticket_detail_updated, units_ticket_detail(identity, "Updated ticket context")})
    assert render(view) =~ "Updated ticket context"
    Phoenix.PubSub.broadcast(Aiur.PubSub, "context-reset-3890", {:ticket_detail_coordinator_reset, 2})
    send(view.pid, {:ticket_detail_updated, units_ticket_detail(identity, "Post-reset ticket context")})
    assert LiveViewAsync.render_after_refresh(view) =~ "Post-reset ticket context"
    view |> element("#units-ticket-context .ticket-context-close") |> render_click()
    refute_receive {:detail_unsubscribed, ^identity}, 100
    assert_receive {:history_unsubscribed, ^identity}, 1000
    refute has_element?(view, "#units-ticket-context")

    html = view |> element(~s(td.ut-id-cell[phx-click="inspect-unit"])) |> render_click()
    assert_receive {:detail_subscribed, ^identity, 2}, 1000
    assert_receive {:history_subscribed, ^identity}, 1000
    refute_receive :ticket_context_resets_subscribed, 100
    assert_receive {:detail_requested, ^identity}, 1000
    assert_receive {:history_requested, ^identity}, 1000
    assert html =~ ~s(id="units-ticket-context")
  end

  test "ticket context replaces identity subscriptions and keeps common resets singular" do
    alpha = units_identity()
    beta = units_identity(repository: "other", provider_id: "NODE-other", database_id: 1111, identifier: "1111")
    membership = units_membership(alpha)
    membership = %{membership | members: membership.members ++ units_membership(beta).members}
    orchestrator_name = Module.concat(__MODULE__, :TicketContextSubscriptionOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()

    alpha_row = units_orchestrator_snapshot(alpha).running |> hd()
    beta_row = units_orchestrator_snapshot(beta).running |> hd() |> Map.put(:issue_id, "issue-1111")
    replace_counting_snapshot(orchestrator, %{units_orchestrator_snapshot(alpha) | running: [alpha_row, beta_row]})

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(alpha) end,
      ticket_context_reset_subscribe_fun: fn ->
        send(test_pid, :context_resets_once)
        :ok
      end,
      ticket_detail_subscribe_fun: &context_subscription(test_pid, :detail_subscribed, &1),
      ticket_history_subscribe_fun: &context_subscription(test_pid, :history_subscribed, &1),
      ticket_detail_unsubscribe_fun: &context_subscription(test_pid, :detail_unsubscribed, &1),
      ticket_history_unsubscribe_fun: &context_subscription(test_pid, :history_unsubscribed, &1),
      ticket_detail_request_fun: fn selected -> {:ok, units_ticket_detail(selected, "Ticket #{selected.identifier}")} end,
      ticket_history_request_fun: fn selected -> {:ok, units_ticket_history(selected)} end
    )

    {:ok, view, _html} = live(build_conn(), "/units")
    assert_receive :context_resets_once, 1000

    alpha_token = UnitsPresenter.row_token(%{identity: alpha})
    beta_token = UnitsPresenter.row_token(%{identity: beta})

    render_hook(view, "inspect-unit", %{"unit" => alpha_token})
    assert_receive {:detail_subscribed, ^alpha}, 1000
    assert_receive {:history_subscribed, ^alpha}, 1000

    render_hook(view, "inspect-unit", %{"unit" => beta_token})
    assert_receive {:detail_unsubscribed, ^alpha}, 1000
    assert_receive {:history_unsubscribed, ^alpha}, 1000
    assert_receive {:detail_subscribed, ^beta}, 1000
    assert_receive {:history_subscribed, ^beta}, 1000

    render_hook(view, "close-ticket-context", %{})
    assert_receive {:detail_unsubscribed, ^beta}, 1000
    assert_receive {:history_unsubscribed, ^beta}, 1000

    render_hook(view, "inspect-unit", %{"unit" => alpha_token})
    assert_receive {:detail_subscribed, ^alpha}, 1000
    assert_receive {:history_subscribed, ^alpha}, 1000
    refute_receive :context_resets_once, 100
  end
end
