defmodule AiurWeb.RefreshSubscriptions do
  @moduledoc false
  alias Aiur.{AgentPubSub, Commands, CurrentRunMembership, CurrentRunOutcomeSnapshot, CurrentRunSummary, OpenTicketSource, TicketActivity}
  alias Aiur.ProviderMeters.Events
  alias AiurWeb.{ObservabilityPubSub, RefreshRelay}
  alias Phoenix.LiveView.Socket

  @spec dashboard(Socket.t()) :: Socket.t()
  def dashboard(socket) do
    RefreshRelay.mount(
      socket,
      fn ->
        :ok = ObservabilityPubSub.subscribe()
        :ok = Commands.subscribe()
        :ok = CurrentRunMembership.subscribe()
        :ok = CurrentRunSummary.subscribe()
        :ok = CurrentRunOutcomeSnapshot.subscribe()
        :ok = TicketActivity.subscribe()
        :ok = OpenTicketSource.subscribe()
      end,
      [
        :observability_updated,
        :decision_changed,
        :decision_metrics_changed,
        :current_run_membership_changed,
        :current_run_membership_health_changed,
        :current_run_summary_changed,
        :current_run_outcome_snapshot_changed,
        :ticket_activity_changed,
        :open_tickets_updated
      ]
    )
  end

  @spec fleet(Socket.t(), (-> term())) :: Socket.t()
  def fleet(socket, subscribe_fixture) do
    RefreshRelay.mount(
      socket,
      fn ->
        :ok = AgentPubSub.subscribe_running()
        :ok = AgentPubSub.subscribe_status()
        :ok = Events.subscribe_observed()
        subscribe_fixture.()
      end,
      [:running_changed, :status_changed, :provider_meter_changed, :streamdeck_fixture_fleet_changed]
    )
  end
end
