defmodule AiurWeb.DashboardLive.Page do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.DashboardLive.CommandHistory
  alias AiurWeb.DashboardLive.Commands
  alias AiurWeb.DashboardLive.Controls
  alias AiurWeb.DashboardLive.ProviderMeters
  alias AiurWeb.DashboardLive.UnitsPanel
  alias AiurWeb.OperatorControlCenter.AddAgentModal
  alias AiurWeb.OperatorControlCenter.AgentLogModal
  alias AiurWeb.OperatorControlCenter.CapacityPresenter
  alias AiurWeb.OperatorControlCenter.CodexHeadroomPresenter
  alias AiurWeb.OperatorControlCenter.ConversationDrawer
  alias AiurWeb.OperatorControlCenter.CurrentRunOutcomesPresenter
  alias AiurWeb.OperatorControlCenter.DashboardShell
  alias AiurWeb.OperatorControlCenter.DecisionInbox
  alias AiurWeb.OperatorControlCenter.History
  alias AiurWeb.OperatorControlCenter.Overview
  alias AiurWeb.OperatorControlCenter.RouteRegistry
  alias AiurWeb.OperatorControlCenter.RunSummaryPresenter
  alias AiurWeb.OperatorControlCenter.RunSummaryStrip
  alias AiurWeb.OperatorControlCenter.TicketContext
  alias AiurWeb.OperatorControlCenter.TicketDetailModal
  alias AiurWeb.OperatorControlCenter.TicketsPanel
  alias AiurWeb.OperatorControlCenter.TicketsPresenter
  alias AiurWeb.OperatorControlCenter.UnitsFilters
  alias AiurWeb.OperatorControlCenter.UnitsPresenter
  alias AiurWeb.OperatorControlCenter.UnitsTable
  alias AiurWeb.OperatorControlCenter.UnitsURL
  alias AiurWeb.OperatorControlCenter.UsageSummaryPresenter
  alias Aiur.Instance.Roster.Presentation, as: RosterPresentation

  @doc false
  @spec page(map()) :: Phoenix.LiveView.Rendered.t()
  def page(assigns) do
    assigns =
      assigns
      |> Map.put_new(:selected_decision_health, nil)
      |> Map.put_new(:retained_counts, Map.get(assigns.payload, :retained_counts, Commands.unavailable_retained_counts()))
      |> Map.put_new(:decision_page, Commands.fallback_decision_page(assigns.payload))
      |> Map.put_new(:decision_query, %{})
      |> Map.put_new(:history_rows, [])
      |> Map.put_new(:history_ids, MapSet.new())
      |> Map.put_new(:history_total, nil)
      |> Map.put_new(:history_has_more, false)
      |> Map.put_new(:history_health, :ok)
      |> Map.put_new(:ticket_context, nil)
      |> Map.put_new(:unit_controls, %{})
      |> Map.put_new(:conversation_drawer, nil)
      |> Map.put_new(:conversation_notice, nil)
      |> Map.put_new(:conversation_origin_id, nil)
      |> Map.put_new(:units_selection, UnitsURL.default_selection())
      |> Map.put_new(
        :units_view,
        UnitsPresenter.project(Map.get(assigns.payload, :units, %{}), Map.get(assigns, :units_selection, UnitsURL.default_selection()))
      )
      |> then(&Map.put_new(&1, :units_announcement, UnitsPresenter.announcement(&1.units_view)))
      |> then(&Map.put_new(&1, :units_count_label, UnitsPanel.units_count_label(&1.units_view)))
      |> Map.put_new(:tickets_view, TicketsPresenter.normalize(Map.get(assigns.payload, :tickets)))
      |> Map.put_new(:tickets_visible, TicketsPresenter.initial_reveal())
      |> Map.put_new(:tickets_query, "")
      |> then(&Map.put_new(&1, :tickets_panel_view, TicketsPresenter.search(&1.tickets_view, &1.tickets_query)))
      |> Map.put_new(:ticket_detail, nil)
      |> Map.put_new(:add_agent_modal, nil)
      |> Map.put_new(:add_agent_pending, nil)
      |> Map.put_new(:add_agent_notice, nil)
      |> Map.put_new(:capacity_view, CapacityPresenter.present(Controls.capacity_facts(assigns.payload)))
      |> Map.put_new(:capacity_input, "")
      |> Map.put_new(:capacity_feedback, nil)
      |> Map.put_new(:run_summary, RunSummaryPresenter.present(nil))
      |> Map.put_new(:run_summary_announcement, nil)
      |> Map.put_new(:usage_summary, UsageSummaryPresenter.present(nil))
      |> Map.put_new(:usage_summary_announcement, nil)
      |> Map.put_new(:usage_summary_drill, nil)
      |> Map.put_new(:usage_summary_drill_trigger, nil)
      |> then(
        &Map.put_new(
          &1,
          :provider_meters_view,
          CodexHeadroomPresenter.provider_meters_view(ProviderMeters.financial_data_capability(&1), %{})
        )
      )
      |> Map.put_new(:provider_meters_announcement, nil)
      |> Map.put_new(:github_quota, %{state: :unknown, windows: %{}, attribution: [], coverage: nil, backoffs: []})
      |> Map.put_new(:instance_agent_roster, :disabled)
      |> Map.put_new(:elevenlabs_quota, %{state: :unconfigured, window: nil, failure: nil, observed_at: nil})
      |> Map.put_new(:voice_capabilities, %{})
      |> Map.put_new(:current_run_outcomes, CurrentRunOutcomesPresenter.present(nil))
      |> Map.put_new(:current_run_outcomes_announcement, nil)
      |> Map.put_new(:current_route, RouteRegistry.current_route(Map.get(assigns, :live_action)))

    ~H"""
    <DashboardShell.dashboard_shell
      route={@current_route}
      routes={RouteRegistry.routes(@payload.analytics)}
      tracker_kind={tracker_kind()}
      agent_kind={agent_kind()}
      nav_counts={AiurWeb.OperatorControlCenter.AwaitingCommands.nav_counts(@retained_counts || %{})}
      nav_collapsed={@nav_collapsed}
      globally_paused={Controls.global_pause_state(@payload)}
      writable={@writable}
    >
      <:banner>
        <AiurWeb.DashboardLive.RepositoryLeaderBanner.banner status={Map.get(assigns, :repository_leader)} />
        <div :if={@global_pause_error} class="readonly-banner global-pause-error" role="alert" aria-live="assertive">
          <span aria-hidden="true">⚠</span>
          <span>{@global_pause_error}</span>
        </div>
        <AiurWeb.OperatorControlCenter.CodeownersTrust.banner now={@now} />
        <Overview.decisions_banner decisions={@payload.decisions} retained_counts={@retained_counts} />
      </:banner>

      <Overview.error error={@payload.fleet[:error]} />

      <div :if={@live_action in [:decisions, :decision]} class="control-panel">
        <div :if={not is_nil(@selected_decision) and Commands.partial_detail?(@selected_decision_health)} class="readonly-banner" role="status" aria-live="polite">
          <span aria-hidden="true">◉</span>
          <span><b>Partial Command data.</b> Some of this detail may be missing.</span>
        </div>
        <div :if={@live_action == :decision and is_nil(@selected_decision)} class="error-card" role="alert">
          <h2>{Commands.selected_decision_error_title(@selected_decision_status)}</h2>
          <p>{Commands.selected_decision_error_message(@selected_decision_status, @selected_decision_id)}</p>
        </div>
        <DecisionInbox.decision_inbox
          decisions={Enum.reject(@decision_page.decisions, &(&1.decision_id == @selected_decision_id))}
          selected_decision={CommandHistory.inbox_selected_decision(@selected_decision, @history_rows)}
          selected_decision_id={@selected_decision_id}
          filter={@decision_filter}
          now={@now}
          history={@payload.history}
          action_states={@decision_actions}
          writable={@writable} live_connected={Map.get(assigns, :live_connected, true)}
          provider_health={Commands.page_provider_health(@decision_page)}
          retained_counts={@retained_counts}
          page={@decision_page}
          query={@decision_query}
          history_total={@history_total}
        />
        <History.history
          rows={@history_rows}
          loaded={MapSet.size(@history_ids)}
          total={@history_total}
          has_more={@history_has_more}
          provider_health={@history_health}
          expanded_id={CommandHistory.history_expanded_id(@selected_decision, @history_rows)}
          expanded_decision={@selected_decision}
          history={@payload.history}
          action_state={CommandHistory.history_action_state(@decision_actions, @selected_decision_id)}
          writable={Map.get(assigns, :writable, false)} live_connected={Map.get(assigns, :live_connected, true)}
          filter={@decision_filter}
          query={@decision_query}
          time_zone={@time_zone}
        />
      </div>

      <div
        :if={@live_action not in [:decisions, :decision]}
        id="usage-watch"
        phx-hook="UsageWatch"
        class="control-panel"
      >
        <RunSummaryStrip.run_summary_strip
          run={@run_summary}
          usage={@usage_summary}
          meters={@provider_meters_view}
          github_quota={@github_quota}
          elevenlabs_quota={@elevenlabs_quota}
          now={@now}
        />

        <section class="section-card units-card" aria-labelledby="route-title">
          <p :if={@conversation_notice} id="conversation-notice" role="status" class="bo-state-card">{@conversation_notice}</p>
          <p id="units-status" class="sr-only" role="status" aria-live="polite" aria-atomic="true">
            {@units_announcement}
          </p>
          <RunSummaryStrip.run_summary_compact
            run={@run_summary}
            usage={@usage_summary}
            meters={@provider_meters_view}
            now={@now}
          />
          <div class="rs-group-head units-group-head">
            <span class="rs-group-title" id="units-title">Units</span>
            <span class="rs-group-count">{@units_count_label}</span>
          </div>
          <UnitsFilters.units_filters
            selection={@units_selection}
            counts={@units_view[:counts] || %{}}
            count_status={@units_view[:count_status] || :unavailable}
          />
          <UnitsTable.units_table view={@units_view} now={@now} controls={@unit_controls} writable={@writable} />
          <section :if={@instance_agent_roster != :disabled} id="instance-agent-list" aria-labelledby="instance-agent-list-title">
            <h3 id="instance-agent-list-title">Agents across instances</h3>
            <%= case @instance_agent_roster do %>
              <% {:ok, %{instances: _instances}} -> %>
                <p :if={instance_agent_rows(@instance_agent_roster) == []}>No agents have been reported by any instance.</p>
                <ul>
                  <li :for={row <- instance_agent_rows(@instance_agent_roster)}
                      data-agent-instance={row.instance.instance_id}
                      data-instance-state={row.instance.state}
                      data-observation-age-ms={row.instance.age_ms}>
                    {row.agent["identifier"] || "unknown ticket"} — {row.agent["state"] || "unknown"} — {row.instance.instance_id}<span :if={row.instance.state == :stale}> (stale)</span> (observed {RosterPresentation.age(row.instance.age_ms)} ago)
                  </li>
                </ul>
              <% {:error, _reason} -> %>
                <p role="alert" data-empty-reason="lease_store_unavailable">Agent roster is unavailable because the shared lease store could not be read.</p>
            <% end %>
          </section>
        </section>

        <%!-- The searched view, so the reveal batches and counts the matches
        rather than the whole backlog behind them. --%>
        <p :if={@add_agent_notice} id="add-agent-notice" class="add-agent-note" role="status">{@add_agent_notice}</p>
        <TicketsPanel.tickets_panel view={@tickets_panel_view} visible={@tickets_visible} writable={@writable} />
      </div>

      <AgentLogModal.agent_log_modal
        :if={is_nil(@conversation_drawer)}
        modal={@agent_log_modal}
        writable={@writable}
        drafts={@drafts}
        errors={@chat_errors}
      />
      <TicketDetailModal.ticket_detail_modal ticket={@ticket_detail} />
      <AddAgentModal.add_agent_modal modal={@add_agent_modal} writable={@writable} />
      <TicketContext.ticket_context
        :if={@ticket_context}
        id="units-ticket-context"
        context={@ticket_context}
        close_event="close-ticket-context"
        fallback_focus_id="route-title"
      />
      <ConversationDrawer.conversation_drawer
        :if={@conversation_drawer}
        id="units-conversation-drawer"
        view={@conversation_drawer}
        composer={@agent_log_modal}
        writable={@writable}
        drafts={@drafts}
        errors={@chat_errors}
        usage_snapshot={@conversation_usage_snapshot}
        usage_error={@conversation_usage_error}
        context_occupancy={Map.get(@conversation_row || %{}, :context_usage)}
        voice_capabilities={@voice_capabilities}
        close_event="close-conversation"
        fallback_focus_id="route-title"
        origin_id={@conversation_origin_id}
      />
    </DashboardShell.dashboard_shell>
    """
  end

  defp instance_agent_rows({:ok, %{instances: instances}}) when is_list(instances) do
    Enum.flat_map(instances, fn instance ->
      Enum.map(Map.get(instance, :agents) || [], &%{agent: &1, instance: instance})
    end)
  end

  defp instance_agent_rows(_unavailable), do: []

  defp tracker_kind, do: to_string(Aiur.Config.tracker_kind())
  defp agent_kind, do: to_string(Aiur.Config.agent_kind())
end
