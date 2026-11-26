defmodule Aiur.Workspace.Preflight do
  @moduledoc "Tracker-owned checks performed before workspace hooks run."

  @callback run(Path.t(), String.t() | nil) :: :ok | {:error, term()}
  @callback local_hold?(term()) :: boolean()
  @callback failure_message(Path.t(), map(), term()) :: String.t()

  @spec registered() :: module() | nil
  def registered do
    Application.get_env(:aiur, :workspace_preflights, %{})
    |> Map.get(Aiur.Config.tracker_kind())
  rescue
    _ -> nil
  end
end
