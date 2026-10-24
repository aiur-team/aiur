defmodule Aiur.Events.GithubCIPoller.CancelledRun do
  @moduledoc "Shared recognition for workflow runs cancelled without a real upstream failure."

  @spec cancelled?(map(), [map()]) :: boolean()
  def cancelled?(%{"event" => event}, jobs) when event in ["merge_group", "pull_request"] and jobs != [] do
    upstream = Enum.reject(jobs, &(&1["name"] == "ci gate"))
    failed_gate? = Enum.any?(jobs, &(&1["name"] == "ci gate" and &1["conclusion"] == "failure"))
    superseded? = Enum.any?(jobs, &(&1["name"] == "ci gate")) and Enum.all?(jobs, &(&1["conclusion"] == "cancelled"))

    superseded? or (failed_gate? and upstream != [] and Enum.all?(upstream, &(&1["conclusion"] == "cancelled")))
  end

  def cancelled?(_run, _jobs), do: false
end
