defmodule AiurWeb.DashboardLive.AddAgentTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.Processes
  import AiurWeb.DashboardLiveSupport.UnitFixtures

  alias Aiur.GitHub.DispatchAuthorization
  alias Aiur.Issue
  alias Aiur.TestSupport.LiveViewAsync
  alias AiurWeb.OperatorControlCenter.AgentRoutingPreview

  @endpoint AiurWeb.Endpoint

  test "Add Agent stays responsive while the tracker blocks and reports completion after closing" do
    test_pid = self()
    orchestrator_name = Module.concat(__MODULE__, :BlockedAddAgentOrchestrator)
    start_counting_orchestrator(orchestrator_name)
    {:ok, boundary} = Agent.start_link(fn -> true end)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      control_center_cache: false,
      dashboard_writable: true,
      open_tickets_fun: fn -> open_ticket_snapshot([open_ticket("2101", [])]) end,
      add_agent_verify_fun: fn _ -> {:ok, [%{dispatch_authorization: :authorized, state: "todo"}]} end,
      add_agent_fun: fn _, label, action ->
        send(test_pid, {action, label})

        if Agent.get_and_update(boundary, &{&1, false}) do
          send(test_pid, {:mutation_blocked, self()})

          receive do
            :continue -> :ok
          end
        else
          :ok
        end
      end
    )

    {:ok, view, _} = live(build_conn(), "/units")
    view |> element(~s(button[phx-click="open-add-agent"])) |> render_click()
    # No intermediate change event: the submitted selection must be authoritative.
    html =
      view
      |> element("#add-agent-modal form")
      |> render_submit(%{"backend" => "codex", "model" => "terra", "complexity" => "3"})

    assert html =~ "Saving labels and checking admission"
    assert has_element?(view, "#add-agent-modal button[type=submit][disabled]")
    receive_barrier({:mutation_blocked, worker})
    view |> element("#add-agent-modal form") |> render_submit(%{})

    view
    |> element(~s(#add-agent-modal header button[phx-click="close-add-agent"]))
    |> render_click()

    refute has_element?(view, "#add-agent-modal")
    # The socket processed Close before the boundary was released.
    send(worker, :continue)
    LiveViewAsync.render_when_complete(view)
    assert render(view) =~ "Waiting for an agent to start"
    assert_received {:add_label, "complexity:3"}
    assert_received {:add_label, "model:codex-terra"}
    refute_received {:mutation_blocked, _}
  end

  test "verified todo admission hints queued demand before completion and Close stays responsive" do
    orchestrator_name = Module.concat(__MODULE__, :QueuedAddAgentOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name, report: self(), block_queued_demand?: true)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      control_center_cache: false,
      dashboard_writable: true,
      open_tickets_fun: fn -> open_ticket_snapshot([open_ticket("2101", ["complexity:3", "agent:todo"])]) end,
      add_agent_verify_fun: fn _ ->
        {:ok, [%{labels: ["complexity:3", "agent:todo"], dispatch_authorization: :authorized, state: "todo"}]}
      end,
      add_agent_fun: fn _, _, _ -> :ok end
    )

    {:ok, view, _} = live(build_conn(), "/units")
    view |> element(~s(button[phx-click="open-add-agent"])) |> render_click()
    view |> element("#add-agent-modal form") |> render_submit(%{})
    assert_receive {:queued_demand_received, ^orchestrator, ["2101"]}, 1_000
    assert has_element?(view, "#add-agent-modal button[type=submit][disabled]")
    refute render(view) =~ "Waiting for an agent to start"

    view
    |> element(~s(#add-agent-modal header button[phx-click="close-add-agent"]))
    |> render_click()

    refute has_element?(view, "#add-agent-modal")
    send(orchestrator, :release_queued_demand)
    LiveViewAsync.render_when_complete(view)
    assert render(view) =~ "Waiting for an agent to start"
    assert_received {:dashboard_refresh_requested, ^orchestrator}
  end

  for {authorization, state} <- [{:denied, "todo"}, {:deferred, "todo"}, {:authorized, "human-review"}] do
    test "Add Agent does not hint queued demand for #{authorization} #{state}" do
      authorization = unquote(authorization)
      state = unquote(state)
      orchestrator_name = Module.concat(__MODULE__, :NonQueuedAddAgentOrchestrator)
      orchestrator = start_counting_orchestrator(orchestrator_name, report: self())

      start_test_endpoint(
        orchestrator: orchestrator_name,
        control_center_cache: false,
        dashboard_writable: true,
        open_tickets_fun: fn -> open_ticket_snapshot([open_ticket("2101", [])]) end,
        add_agent_verify_fun: fn _ ->
          {:ok, [%{dispatch_authorization: authorization, state: state}]}
        end,
        add_agent_fun: fn _, _, _ -> :ok end
      )

      {:ok, view, _} = live(build_conn(), "/units")
      view |> element(~s(button[phx-click="open-add-agent"])) |> render_click()
      view |> element("#add-agent-modal form") |> render_submit(%{})
      LiveViewAsync.render_when_complete(view)
      refute_received {:queued_demand_received, ^orchestrator, _}
      refute has_element?(view, "#add-agent-modal")
    end
  end

  test "Add Agent retains successful removals on error and retry applies only remaining changes" do
    test_pid = self()
    orchestrator_name = Module.concat(__MODULE__, :PartialAddAgentOrchestrator)
    start_counting_orchestrator(orchestrator_name)
    {:ok, boundary} = Agent.start_link(fn -> %{fail?: true, labels: ["complexity:5"]} end)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      control_center_cache: false,
      dashboard_writable: true,
      open_tickets_fun: fn -> open_ticket_snapshot([open_ticket("2101", ["complexity:5"])]) end,
      add_agent_verify_fun: fn _ ->
        # Agent-created ticket, no prior human triage: exercise the actual gate.
        issue = %Issue{
          id: "2649",
          identifier: "2649",
          state: "todo",
          labels: Agent.get(boundary, & &1.labels),
          creator_login: "aiur-bot"
        }

        events = [
          %{
            "id" => 1,
            "event" => "labeled",
            "label" => %{"name" => "agent:todo"},
            "actor" => %{"login" => "aiur-daemon[bot]"},
            "created_at" => "2026-09-16T00:00:00Z"
          }
        ]

        authorized =
          DispatchAuthorization.authorize(issue, "test", "repo", "agent",
            allowed_users: ["operator"],
            bot_account: "aiur-bot",
            daemon_account: "aiur-daemon[bot]",
            token: "test",
            request_fun: fn _ -> {:ok, %{status: 200, body: events, headers: []}} end
          )

        {:ok, [authorized]}
      end,
      add_agent_fun: fn _, label, action ->
        send(test_pid, {action, label})

        Agent.get_and_update(boundary, fn state ->
          cond do
            action == :add_label and state.fail? -> {{:error, :offline}, %{state | fail?: false}}
            action == :add_label -> {:ok, %{state | labels: Enum.uniq(state.labels ++ [label])}}
            true -> {:ok, %{state | labels: state.labels -- [label]}}
          end
        end)
      end
    )

    {:ok, view, _} = live(build_conn(), "/units")
    view |> element(~s(button[phx-click="open-add-agent"])) |> render_click()

    view
    |> element("#add-agent-modal form")
    |> render_submit(%{"backend" => "codex", "complexity" => "3"})

    LiveViewAsync.render_when_complete(view)
    assert has_element?(view, "#add-agent-modal")
    assert render(view) =~ "removed complexity:5"
    assert render(view) =~ "offline"
    assert_received {:remove_label, "complexity:5"}
    view |> element("#add-agent-modal form") |> render_submit(%{})
    LiveViewAsync.render_when_complete(view)
    refute_received {:remove_label, "complexity:5"}
    refute has_element?(view, "#add-agent-modal")
    assert render(view) =~ "dispatch authorization declined"
    assert render(view) =~ "using their own account"
  end

  test "already labelled tickets can check admission without pretending that an agent is running" do
    test_pid = self()
    orchestrator_name = Module.concat(__MODULE__, :RetryAdmissionOrchestrator)
    start_counting_orchestrator(orchestrator_name)
    {:ok, authorization} = Agent.start_link(fn -> :deferred end)

    labels =
      AgentRoutingPreview.plan(%{backend: "codex", model: nil, effort: nil, complexity: nil}, []).add

    start_test_endpoint(
      orchestrator: orchestrator_name,
      control_center_cache: false,
      dashboard_writable: true,
      open_tickets_fun: fn -> open_ticket_snapshot([open_ticket("2101", labels)]) end,
      add_agent_verify_fun: fn _ ->
        send(test_pid, :admission_checked)
        {:ok, [%{dispatch_authorization: Agent.get(authorization, & &1)}]}
      end,
      add_agent_fun: fn _, _, _ -> flunk("already applied labels must not be rewritten") end
    )

    {:ok, view, _} = live(build_conn(), "/units")
    view |> element(~s(button[phx-click="open-add-agent"])) |> render_click()
    # Explicitly choose the labels already carried by this ticket.
    view |> element("#add-agent-modal form") |> render_change(%{"backend" => "codex"})
    assert render(view) =~ "Check admission"
    refute has_element?(view, "#add-agent-modal button[type=submit][disabled]")
    view |> element("#add-agent-modal form") |> render_submit(%{})
    LiveViewAsync.render_when_complete(view)
    assert_received :admission_checked
    assert render(view) =~ "No admission is confirmed"
    Agent.update(authorization, fn _ -> :unknown end)
    view |> element(~s(button[phx-click="open-add-agent"])) |> render_click()
    view |> element("#add-agent-modal form") |> render_change(%{"backend" => "codex"})
    view |> element("#add-agent-modal form") |> render_submit(%{})
    LiveViewAsync.render_when_complete(view)
    assert render(view) =~ "Admission could not be confirmed"
    refute render(view) =~ "Waiting for an agent to start"
  end

  test "the add-agent modal opens on a routed family alias rather than the version it resolves to" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), agent_routing: %{3 => "codex:sol"})

    identity = units_identity()
    orchestrator_name = Module.concat(__MODULE__, :TicketsAliasOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      open_tickets_fun: fn -> open_ticket_snapshot([open_ticket("2103", ["complexity:3"])]) end
    )

    {:ok, view, _html} = live(build_conn(), "/units")

    routing = AgentRoutingPreview.preview(["complexity:3"])
    assert routing.model == "sol"
    assert routing.resolved_model != "sol", "only meaningful while `sol` resolves to a concrete version"

    view |> element(~s(button[phx-click="open-add-agent"])) |> render_click()

    assert selected_option(render(view), "model") == "sol"
  end
end
