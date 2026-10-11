defmodule AiurWeb.DashboardLive.Summaries do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Aiur.{CurrentRunOutcomeSnapshot, CurrentRunSummary}
  alias AiurWeb.Endpoint
  alias AiurWeb.OperatorControlCenter.{CurrentRunOutcomesPresenter, RunSummaryPresenter}

  @run_summary_flush_ms 250
  @current_run_outcomes_flush_ms 250

  # Read the current DASH-014 snapshot on mount/reconnect. On the dead first
  # render, or when the projection process is unreachable, fall back to the
  # loading view rather than crashing the LiveView.
  @doc false
  @spec assign_initial_run_summary(Phoenix.LiveView.Socket.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def assign_initial_run_summary(socket, connected) do
    snapshot = if connected, do: read_run_summary_snapshot(), else: nil

    socket
    |> assign(:run_summary_source, nil)
    |> assign(:run_summary_pending, nil)
    |> assign(:run_summary_flush_scheduled?, false)
    |> apply_run_summary(snapshot)
  end

  defp read_run_summary_snapshot do
    CurrentRunSummary.snapshot()
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  # Coalesce bursts of daemon updates: keep only the latest pending snapshot
  # and flush once per debounce window so high-frequency renders and
  # screen-reader announcements stay bounded.
  @doc false
  @spec stash_run_summary(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def stash_run_summary(socket, snapshot) do
    socket = assign(socket, :run_summary_pending, snapshot)

    if socket.assigns.run_summary_flush_scheduled? do
      socket
    else
      schedule_run_summary_flush()
      assign(socket, :run_summary_flush_scheduled?, true)
    end
  end

  @doc false
  @spec flush_run_summary(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def flush_run_summary(socket) do
    socket = assign(socket, :run_summary_flush_scheduled?, false)

    case socket.assigns.run_summary_pending do
      nil -> socket
      snapshot -> socket |> assign(:run_summary_pending, nil) |> apply_run_summary(snapshot)
    end
  end

  # Reconcile an incoming snapshot against the displayed source (last-known-good
  # retention lives in the presenter) and assign the presented view plus a
  # single bounded announcement.
  defp apply_run_summary(socket, snapshot) do
    {source, retained?} = RunSummaryPresenter.reconcile(socket.assigns.run_summary_source, snapshot)
    status_source = if retained?, do: snapshot, else: nil
    view = RunSummaryPresenter.present(source, retained?, status_source)

    socket
    |> assign(:run_summary_source, source)
    |> assign(:run_summary, view)
    |> assign(:run_summary_announcement, RunSummaryPresenter.announcement(view))
  end

  defp schedule_run_summary_flush do
    case Endpoint.config(:run_summary_flush_timer) do
      timer when is_function(timer, 3) -> timer.(self(), :flush_run_summary, @run_summary_flush_ms)
      _other -> Process.send_after(self(), :flush_run_summary, @run_summary_flush_ms)
    end
  end

  @doc false
  @spec assign_initial_current_run_outcomes(Phoenix.LiveView.Socket.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def assign_initial_current_run_outcomes(socket, connected) do
    snapshot = if connected, do: read_current_run_outcomes_snapshot(), else: nil

    socket
    |> assign(:current_run_outcomes_source, nil)
    |> assign(:current_run_outcomes_pending, nil)
    |> assign(:current_run_outcomes_flush_scheduled?, false)
    |> apply_current_run_outcomes(snapshot)
  end

  defp read_current_run_outcomes_snapshot do
    CurrentRunOutcomeSnapshot.snapshot()
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  # Coalesce bursts of daemon updates: keep only the latest pending snapshot and
  # flush once per debounce window so high-frequency renders and screen-reader
  # announcements stay bounded.
  @doc false
  @spec stash_current_run_outcomes(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def stash_current_run_outcomes(socket, snapshot) do
    socket = assign(socket, :current_run_outcomes_pending, snapshot)

    if socket.assigns.current_run_outcomes_flush_scheduled? do
      socket
    else
      schedule_current_run_outcomes_flush()
      assign(socket, :current_run_outcomes_flush_scheduled?, true)
    end
  end

  @doc false
  @spec flush_current_run_outcomes(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def flush_current_run_outcomes(socket) do
    socket = assign(socket, :current_run_outcomes_flush_scheduled?, false)

    case socket.assigns.current_run_outcomes_pending do
      nil -> socket
      snapshot -> socket |> assign(:current_run_outcomes_pending, nil) |> apply_current_run_outcomes(snapshot)
    end
  end

  # Reconcile an incoming snapshot against the displayed source (last-known-good
  # retention lives in the presenter) and assign the presented, generation-pinned
  # view plus a single bounded announcement.
  defp apply_current_run_outcomes(socket, snapshot) do
    {source, retained?} = CurrentRunOutcomesPresenter.reconcile(socket.assigns.current_run_outcomes_source, snapshot)
    status_source = if retained?, do: snapshot, else: nil
    view = CurrentRunOutcomesPresenter.present(source, retained?, status_source)

    socket
    |> assign(:current_run_outcomes_source, source)
    |> assign(:current_run_outcomes, view)
    |> assign(:current_run_outcomes_announcement, CurrentRunOutcomesPresenter.announcement(view))
  end

  defp schedule_current_run_outcomes_flush do
    case Endpoint.config(:current_run_outcomes_flush_timer) do
      timer when is_function(timer, 3) -> timer.(self(), :flush_current_run_outcomes, @current_run_outcomes_flush_ms)
      _other -> Process.send_after(self(), :flush_current_run_outcomes, @current_run_outcomes_flush_ms)
    end
  end
end
