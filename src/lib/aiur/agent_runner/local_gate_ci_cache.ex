defmodule Aiur.AgentRunner.LocalGateCICache do
  @moduledoc false

  alias Aiur.Orchestrator.Client

  @snapshot_timeout_ms 1_000

  @doc false
  @spec read(GenServer.server(), String.t()) :: map() | :unavailable
  def read(orchestrator, identifier) when is_binary(identifier) do
    case Client.dashboard_snapshot(orchestrator, @snapshot_timeout_ms) do
      {:current, snapshot, _freshness} ->
        snapshot
        |> running_ci_result(identifier)
        |> current_observation()

      _stale_or_unavailable ->
        :unavailable
    end
  rescue
    _error -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  def read(_orchestrator, _identifier), do: :unavailable

  @doc false
  @spec green_current?(map() | term(), integer(), pos_integer()) :: boolean()
  def green_current?(%{decision: :passed, head_sha: head, observed_at_ms: observed}, now_ms, max_age_ms)
      when is_binary(head) and head != "" and is_integer(observed) do
    age = now_ms - observed
    age >= 0 and age <= max_age_ms
  end

  def green_current?(_result, _now_ms, _max_age_ms), do: false

  defp running_ci_result(snapshot, identifier) do
    snapshot
    |> Map.get(:running, [])
    |> Enum.find(&(&1[:identifier] == identifier))
    |> case do
      %{ci_result: result} when is_map(result) -> result
      _missing -> :unavailable
    end
  end

  defp current_observation(%{observed_at_ms: observed} = result) when is_integer(observed),
    do: result

  defp current_observation(_result), do: :unavailable
end
