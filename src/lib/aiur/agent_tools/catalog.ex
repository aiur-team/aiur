defmodule Aiur.AgentTools.Catalog do
  @moduledoc "The shared Aiur coordination tool catalog exposed to coding agents."

  alias Aiur.Codex.DynamicTool

  @spec specs() :: [map()]
  def specs, do: DynamicTool.tool_specs()

  @spec names() :: [String.t()]
  def names, do: Enum.map(specs(), & &1["name"])
end
