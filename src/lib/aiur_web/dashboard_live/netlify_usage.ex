defmodule AiurWeb.DashboardLive.NetlifyUsage do
  @moduledoc "Loads Netlify usage for the dashboard and refreshes it with the runtime tick."
  alias Aiur.Netlify.Usage
  alias AiurWeb.DashboardLive.RepositoryLeaderBanner

  @spec snapshot() :: %{enabled?: boolean(), snapshot: map()}
  def snapshot do
    snapshot =
      case Process.whereis(Usage) do
        nil -> unavailable_snapshot()
        _pid -> Usage.snapshot()
      end

    %{snapshot: snapshot, enabled?: Aiur.Config.netlify_settings().enabled}
  end

  defp unavailable_snapshot do
    %{
      provider: :netlify,
      state: :unavailable,
      reason: :not_observed,
      observed_at: nil,
      age_ms: nil,
      freshness: :unknown,
      source: "netlify.usage",
      fields: %{}
    }
  end

  @spec tick(Phoenix.LiveView.Socket.t(), (-> term())) :: Phoenix.LiveView.Socket.t()
  def tick(socket, schedule) do
    schedule.()
    socket |> RepositoryLeaderBanner.refresh() |> Phoenix.Component.assign(:netlify_dashboard, snapshot())
  end
end
