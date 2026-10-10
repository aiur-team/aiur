defmodule Aiur.AgentListRendererSupport do
  @moduledoc false

  alias Aiur.AgentList.Renderer

  def render(state), do: IO.iodata_to_binary(Renderer.render(state))

  def visible(text), do: Regex.replace(~r/\e\[[?0-9;]*[A-Za-z]/, text, "")

  def base_state(overrides \\ %{}) do
    Map.merge(
      %{
        summaries: [],
        selection_index: 0,
        columns: 60,
        rows: 20,
        project_label: nil,
        dashboard_url: nil,
        agent_kind: nil,
        agent_count: nil,
        max_agents: nil
      },
      overrides
    )
  end
end
