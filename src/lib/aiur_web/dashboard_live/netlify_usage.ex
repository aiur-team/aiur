defmodule AiurWeb.DashboardLive.NetlifyUsage do
  @moduledoc "Loads Netlify usage for the dashboard and refreshes it with the runtime tick."
  alias Aiur.Netlify.Usage
  alias AiurWeb.DashboardLive.RepositoryLeaderBanner

  @spec snapshot() :: %{enabled?: boolean(), snapshot: map()}
  def snapshot, do: %{snapshot: Usage.snapshot(), enabled?: Aiur.Config.netlify_settings().enabled}

  @spec tick(Phoenix.LiveView.Socket.t(), (-> term())) :: Phoenix.LiveView.Socket.t()
  def tick(socket, schedule) do
    schedule.()
    socket |> RepositoryLeaderBanner.refresh() |> Phoenix.Component.assign(:netlify_dashboard, snapshot())
  end
end
