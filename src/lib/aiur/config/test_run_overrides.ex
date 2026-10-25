defmodule Aiur.Config.TestRunOverrides do
  @moduledoc """
  Capacity overrides for an `aiurdev --test` / `--test3` sandbox run (#5121).

  The sandbox daemon shares the host with the live fleet, so the host load and
  CPU PSI it would gate on are the fleet's, not its own. A sandbox run caps
  admission at its pinned ticket count and disables those host gates.
  """

  alias Aiur.TestRunState

  @spec apply({:ok, Aiur.Config.Schema.t()} | {:error, term()}) :: {:ok, Aiur.Config.Schema.t()} | {:error, term()}
  def apply({:ok, settings}) do
    if TestRunState.active?(), do: {:ok, override(settings)}, else: {:ok, settings}
  end

  def apply(error), do: error

  defp override(%{agent: agent} = settings) do
    pinned = "AIUR_DEV_TEST_TICKET_IDS" |> System.get_env() |> String.split(",") |> length()

    %{
      settings
      | agent: %{
          agent
          | max_concurrent_agents: pinned,
            max_concurrent_agents_by_state: %{},
            max_cpu_pressure: nil,
            target_cpu_pressure: nil,
            max_load_average: nil,
            target_load_average: nil,
            run_queue_threshold: nil
        }
    }
  end
end
