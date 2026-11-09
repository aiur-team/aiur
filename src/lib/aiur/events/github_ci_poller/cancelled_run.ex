defmodule Aiur.Events.GithubCIPoller.CancelledRun do
  @moduledoc "Shared recognition for workflow runs cancelled without a real upstream failure."

  @spec cancelled?(map(), [map()]) :: boolean()
  def cancelled?(%{"event" => event}, jobs) when event in ["merge_group", "pull_request"] and jobs != [] do
    upstream = Enum.reject(jobs, &(&1["name"] == "ci gate"))
    cancelled? = Enum.any?(upstream, &(&1["conclusion"] == "cancelled"))
    no_real_failure? = Enum.all?(upstream, &(&1["conclusion"] not in ["failure", "timed_out", "startup_failure", "action_required"]))
    failed_gate? = Enum.any?(jobs, &(&1["name"] == "ci gate" and &1["conclusion"] == "failure"))
    superseded? = Enum.any?(jobs, &(&1["name"] == "ci gate")) and Enum.all?(jobs, &(&1["conclusion"] == "cancelled"))

    superseded? or (failed_gate? and cancelled? and no_real_failure?)
  end

  def cancelled?(_run, _jobs), do: false
end
