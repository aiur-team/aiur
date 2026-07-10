defmodule Aiur.Codex.DynamicTool.Handler do
  @moduledoc """
  Behaviour for a dynamic-tool handler module.
  """

  @callback tools() :: [String.t()]
  @callback specs() :: [map()]
  @callback execute(String.t(), term(), keyword()) :: map()
end
