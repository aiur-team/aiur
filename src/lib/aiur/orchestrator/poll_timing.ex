defmodule Aiur.Orchestrator.PollTiming do
  @moduledoc false
  require Logger

  @spec complete(map(), term()) :: map()
  def complete(%{poll_cycles_completed: 0} = state, {:ok, issues, _cache}) when is_list(issues) do
    elapsed = System.convert_time_unit(System.monotonic_time() - :erlang.system_info(:start_time), :native, :millisecond)
    Logger.info("Dispatch candidate poll completed boot_elapsed_ms=#{elapsed} issue_count=#{length(issues)}")
    state
  end

  def complete(state, _result), do: state
end
