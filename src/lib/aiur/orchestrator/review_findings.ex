defmodule Aiur.Orchestrator.ReviewFindings do
  @moduledoc false

  defdelegate blocking_body?(body), to: Aiur.PRLifecycle.ReviewFindings
end
