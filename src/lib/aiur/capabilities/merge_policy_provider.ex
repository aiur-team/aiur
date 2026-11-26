defmodule Aiur.Capabilities.MergePolicyProvider do
  @moduledoc "Merge policy's contribution to the instance capability registry."
  @behaviour Aiur.Capabilities.Provider

  @impl true
  def capability_ids, do: ["merge_policy"]

  @impl true
  def capabilities(_context) do
    policy = Aiur.MergePolicy.current()
    %{"merge_policy" => %{state: :available, mode: "ci=#{policy.ci} local_tests=#{policy.local_tests}"}}
  end
end
