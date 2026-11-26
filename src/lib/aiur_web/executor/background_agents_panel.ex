defmodule AiurWeb.Executor.BackgroundAgentsPanel do
  @moduledoc false
  use Phoenix.Component

  alias Aiur.Instance.Roster.Presentation

  attr(:snapshot, :any, required: true)
  attr(:now, :any, required: true)

  @spec panel(map()) :: Phoenix.LiveView.Rendered.t()
  def panel(assigns) do
    ~H"""
    <section id="executor-background-agents" aria-labelledby="executor-background-agents-heading">
      <h2 id="executor-background-agents-heading">Background agents</h2>
      <p :if={match?({:unsupported, _}, @snapshot)}>Not available for this harness ({elem(@snapshot, 1)})</p>
      <p :if={match?({:ok, [], _}, @snapshot)}>No background agents</p>
      <ul :if={rows(@snapshot) != []}>
        <li :for={row <- rows(@snapshot)}>
          <strong>{row.agent_type || row.agent_id}</strong>
          <span>{row.state} · {age(row.started_at, @now)}</span>
          <p :if={row.last_message}>{String.slice(row.last_message, 0, 500)}</p>
        </li>
      </ul>
    </section>
    """
  end

  defp rows({:ok, rows, _observed_since}), do: rows
  defp rows({:unsupported, _reason}), do: []

  defp age(%DateTime{} = started_at, now), do: Presentation.age(max(DateTime.diff(now, started_at, :millisecond), 0))
  defp age(nil, _now), do: "age unknown"
end
