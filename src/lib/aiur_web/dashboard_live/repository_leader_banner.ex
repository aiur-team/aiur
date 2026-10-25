defmodule AiurWeb.DashboardLive.RepositoryLeaderBanner do
  @moduledoc false
  use Phoenix.Component

  alias Aiur.Instance.RepositoryLeader

  @refresh_interval_seconds 15
  @clock_key {__MODULE__, :clock}
  @status_fun_key {__MODULE__, :status_fun}

  @spec initial_status() :: map()
  def initial_status do
    %{leader: "unknown", lease_age: "unknown", observed_at: now(), freshness: :pending}
  end

  @spec refresh(Phoenix.LiveView.Socket.t(), (-> map())) :: Phoenix.LiveView.Socket.t()
  def refresh(socket, status_fun \\ &RepositoryLeader.status/0) do
    now = now()
    socket = assign(socket, :now, now)
    status = socket.assigns.repository_leader
    status_fun = Process.get(@status_fun_key) || status_fun

    if status.freshness == :pending or DateTime.diff(now, status.observed_at, :second) >= @refresh_interval_seconds do
      assign(socket, :repository_leader, status_fun.())
    else
      socket
    end
  end

  @doc false
  @spec put_status_fun((-> map())) :: :ok
  def put_status_fun(status_fun) when is_function(status_fun, 0) do
    Process.put(@status_fun_key, status_fun)
    :ok
  end

  @doc false
  @spec clear_status_fun() :: :ok
  def clear_status_fun do
    Process.delete(@status_fun_key)
    :ok
  end

  @doc false
  @spec put_clock((-> DateTime.t())) :: :ok
  def put_clock(clock_fun) when is_function(clock_fun, 0) do
    Process.put(@clock_key, clock_fun)
    :ok
  end

  @doc false
  @spec clear_clock() :: :ok
  def clear_clock do
    Process.delete(@clock_key)
    :ok
  end

  defp now do
    case Process.get(@clock_key) do
      clock_fun when is_function(clock_fun, 0) -> clock_fun.()
      _ -> DateTime.utc_now()
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
