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

  defp icon(key, text), do: %__MODULE__{key: key, text: text}
end
