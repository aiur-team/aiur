defmodule Aiur.AgentTools.Catalog do
  @moduledoc "The shared Aiur coordination tool catalog exposed to coding agents."

  alias Aiur.AgentTools.Dispatch

  @spec specs() :: [map()]
  def specs, do: Dispatch.tool_specs()

  @spec names() :: [String.t()]
  def names, do: Enum.map(specs(), & &1["name"])
end
