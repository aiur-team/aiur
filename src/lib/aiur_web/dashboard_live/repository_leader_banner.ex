defmodule AiurWeb.DashboardLive.RepositoryLeaderBanner do
  @moduledoc false
  use Phoenix.Component

  alias Aiur.Instance.RepositoryLeader

  @refresh_interval_seconds 15

  @spec initial_status() :: map()
  def initial_status do
    %{leader: "unknown", lease_age: "unknown", observed_at: DateTime.utc_now(), freshness: :pending}
  end

  @spec refresh(Phoenix.LiveView.Socket.t(), (-> map())) :: Phoenix.LiveView.Socket.t()
  def refresh(socket, status_fun \\ &RepositoryLeader.status/0) do
    now = DateTime.utc_now()
    socket = assign(socket, :now, now)
    status = socket.assigns.repository_leader

    if status.freshness == :pending or DateTime.diff(now, status.observed_at, :second) >= @refresh_interval_seconds do
      assign(socket, :repository_leader, status_fun.())
    else
      socket
    end
  end

  @spec banner(map()) :: Phoenix.LiveView.Rendered.t()
  def banner(%{status: nil} = assigns), do: banner(assign(assigns, :status, initial_status()))

  def banner(assigns) do
    ~H"""
    <div class="readonly-banner" role="status" aria-live="polite">
      <span>
        {RepositoryLeader.status_text(@status)} ·
        <span :if={@status.freshness == :pending}>status refresh pending</span>
        <span :if={@status.freshness != :pending}>
          status refreshed
          <time datetime={DateTime.to_iso8601(@status.observed_at)}>{Calendar.strftime(@status.observed_at, "%H:%M:%S UTC")}</time>
        </span>
      </span>
    </div>
    """
  end
end
