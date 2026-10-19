defmodule Aiur.BrowserHarness.RouteShellLive do
  use Phoenix.LiveView, layout: {Aiur.BrowserHarness.FixtureLayout, :app}
  alias Aiur.BrowserHarness.CommandAnswerFixture
  alias AiurWeb.DashboardLive
  alias AiurWeb.OperatorControlCenter.{DashboardShell, History, NavState, RouteRegistry}

  @impl true
  def mount(params, session, socket) do
    if CommandAnswerFixture.configured?(params) do
      :ets.insert(
        AiurWeb.EndpointConfig.overrides_table(),
        {{self(), :decision_store}, CommandAnswerFixture.store_name()}
      )

      if Phoenix.LiveView.connected?(socket) and CommandAnswerFixture.join_delay_ms() > 0 do
        CommandAnswerFixture.join_started!()
        Process.sleep(CommandAnswerFixture.join_delay_ms())
        CommandAnswerFixture.join_completed!()
      end

      # Production's live_session hooks, run here so the fixture keeps one root layout and LiveSocket.
      {:cont, socket} = AiurWeb.DashboardPagesGate.on_mount(:default, params, session, socket)
      {:cont, socket} = AiurWeb.FinancialDataAccess.on_mount(:default, params, session, socket)

      with {:ok, socket} <- DashboardLive.mount(params, session, socket) do
        {:ok, assign(socket, :fixture_command_answer_dashboard?, true)}
      end
    else
      {:ok,
       socket
       |> assign(:analytics, analytics(%{}))
       |> assign(:live_connected, Phoenix.LiveView.connected?(socket))
       |> assign(:selected_decision_id, nil)
       |> assign(:selected_decision, nil)
       |> assign(:decision_actions, %{})
       |> NavState.assign_nav()
       |> assign(:current_route, RouteRegistry.current_route(socket.assigns.live_action))}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    if Map.get(socket.assigns, :fixture_command_answer_dashboard?, false) do
      DashboardLive.handle_params(params, uri, socket)
    else
      decision_id = params["decision_id"] || params["fixture_decision"]

      {:noreply,
       socket
       |> assign(:analytics, analytics(params))
       |> assign(:selected_decision_id, decision_id)
       |> assign(:current_route, RouteRegistry.current_route(socket.assigns.live_action))}
    end
  end

  @impl true
  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}
  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket), do: {:noreply, NavState.restore(socket, collapsed)}

  def handle_event(event, params, %{assigns: %{fixture_command_answer_dashboard?: true}} = socket) do
    DashboardLive.handle_event(event, params, socket)
  end

  @impl true
  def handle_info(message, %{assigns: %{fixture_command_answer_dashboard?: true}} = socket) do
    DashboardLive.handle_info(message, socket)
  end

  @impl true
  def render(assigns) do
    if Map.get(assigns, :fixture_command_answer_dashboard?, false) do
      DashboardLive.render(assigns)
    else
      render_route_shell(assigns)
    end
  end

  defp render_route_shell(assigns) do
    ~H"""
    <main class="app-shell">
      <DashboardShell.dashboard_shell
        route={@current_route}
        routes={RouteRegistry.routes(@analytics)}
        tracker_kind="fixture"
        agent_kind="fixture"
        nav_collapsed={@nav_collapsed}
      >
        <section class="section-card" aria-labelledby="route-shell-fixture-title">
          <h2 id="route-shell-fixture-title">Route shell fixture</h2>
          <p>This authenticated LiveView fixture verifies the shared route shell without inventing operational data.</p>
          <button id="route-shell-action" type="button">Reachable action</button>
        </section>
        <%!-- Command history is an accordion whose rows patch to the Command's
              own URL, so it can only be exercised on the real `/commands` and
              `/commands/:decision_id` routes the shell fixture already owns. --%>
        <History.history
          :if={@live_action in [:decisions, :decision]}
          rows={history_decisions()}
          loaded={3}
          total={3}
          expanded_id={@selected_decision_id}
          expanded_decision={Enum.find(history_decisions(), &(&1.decision_id == @selected_decision_id))}
          writable={false}
          time_zone="Etc/UTC"
        />
      </DashboardShell.dashboard_shell>
    </main>
    """
  end

  defp history_decisions do
    [
      history_decision("answered-command",
        question: "Who reviews the merge queue backlog?",
        decision_status: :decided,
        answer: %{
          action_id: "act-answered",
          decision_version: 1,
          selected_option_id: nil,
          custom_response: "it is the executor's job to review",
          rationale: nil,
          actor: %{kind: :operator, id: "operator"},
          accepted_at: ~U[2026-07-18 11:05:00Z]
        }
      ),
      history_decision("expired-command",
        question: "Should the release wait for the flaky suite?",
        decision_status: :expired
      ),
      history_decision("deferred-command",
        question: "Which migration order is safe?",
        decision_status: :deferred
      )
    ]
  end

  defp history_decision(decision_id, attrs) do
    Map.merge(
      %{
        decision_id: decision_id,
        version: 1,
        ticket: %{identifier: "AIUR-#{:erlang.phash2(decision_id, 900) + 100}", title: "Fixture ticket"},
        source: %{agent_id: "agent-1"},
        kind: "architecture",
        authority: :human_required,
        urgency: :normal,
        blocking: false,
        reversibility: :reversible,
        context: %{short: "Fixture context summary", long_markdown: "The retained Command context lives here."},
        options: [%{id: "ship", label: "Ship it", description: "Proceed", risk: "low"}],
        recommendation: nil,
        consequence_of_delay: nil,
        artifacts: [],
        created_at: ~U[2026-07-18 11:00:00Z],
        delivery_status: :delivered,
        answer: nil,
        retryable: false,
        failure_reason: nil,
        superseded?: false,
        revisions: [],
        revision_sequence: 0,
        lifecycle: :resolved
      },
      Map.new(attrs)
    )
  end

  defp analytics(%{"analytics" => "unavailable"}) do
    %{experiments_available?: true, available?: false, path: nil, message: "Telemetry analytics are unavailable in this fixture."}
  end

  defp analytics(_params) do
    %{experiments_available?: true, available?: true, path: "/analytics", message: "Open fixture analytics."}
  end
end
