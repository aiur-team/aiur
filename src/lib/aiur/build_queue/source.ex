defmodule Aiur.BuildQueue.Source do
  @moduledoc "Dependency inputs supply queue members, edges and explicit freshness."
  alias Aiur.BuildQueue.Model

  @type freshness :: :current | :stale | :unknown
  @callback members(Model.Queue.t(), Model.t()) :: {:ok, [Model.Item.t()], [Model.Edge.t()], freshness()} | {:unavailable, term()}
end
