defmodule Aiur.BuildOrder.Icon do
  @moduledoc "Aiur-owned lane and status presentation hints with accessible fallbacks."

  @type t :: %__MODULE__{key: atom(), text: String.t()}

  defstruct [:key, :text]

  @spec lane(term()) :: t()
  def lane("plan-graph"), do: icon(:lane_plan_graph, "Plan graph lane")
  def lane("runtime"), do: icon(:lane_runtime, "Runtime lane")
  def lane("dashboard-ui"), do: icon(:lane_dashboard_ui, "Dashboard interface lane")
  def lane("accounting"), do: icon(:lane_accounting, "Accounting lane")
  def lane("platform"), do: icon(:lane_platform, "Platform lane")
  def lane(_lane), do: icon(:lane_generic, "Build lane unavailable")

  @spec status(term()) :: t()
  def status(:ready), do: icon(:status_ready, "Ready")
  def status(:blocking), do: icon(:status_blocking, "Blocked by an open dependency")

  def status(:terminal_unsatisfied),
    do: icon(:status_terminal_unsatisfied, "Blocked by an unsatisfied terminal dependency")

  def status(:unknown), do: icon(:status_unknown, "Dependency status unavailable")
  def status(:cyclic), do: icon(:status_cyclic, "Dependency cycle detected")
  def status(_status), do: icon(:status_generic, "Status unavailable")

  @doc """
  Derives a presentation hint without collapsing the underlying facts.

  GitHub terminal truth wins, then an active Aiur execution overlay, then the
  dependency-readiness state. The presenter retains all three source values.
  """
  @spec status(term(), term(), term()) :: t()
  def status(lifecycle, readiness, execution) do
    case lifecycle_status(lifecycle) do
      nil -> execution_status(execution) || status(readiness)
      terminal -> terminal
    end
  end

  defp lifecycle_status(%{state: :closed, state_reason: :completed}),
    do: icon(:status_completed, "Completed")

  defp lifecycle_status(%{state: :closed, state_reason: reason})
       when reason in [:not_planned, :duplicate],
       do: icon(:status_not_planned, "Closed without completion")

  defp lifecycle_status(_lifecycle), do: nil

  defp execution_status(%{status: :known, tracker_paused: true}),
    do: icon(:status_paused, "Paused")

  defp execution_status(%{status: :known, work_state: state})
       when state in [:paused, :pausing],
       do: icon(:status_paused, "Paused")

  defp execution_status(%{status: :known, kind: :retrying}),
    do: icon(:status_retrying, "Waiting to retry")

  defp execution_status(%{status: :known, waiting_reason: reason})
       when is_atom(reason) and reason not in [nil, :active, :unknown],
       do: icon(:status_waiting, "Waiting")

  defp execution_status(%{status: :known, kind: :running}),
    do: icon(:status_working, "Agent working")

  defp execution_status(_execution), do: nil

  defp icon(key, text), do: %__MODULE__{key: key, text: text}
end
