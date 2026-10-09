defmodule Aiur.MergePolicyCLI do
  @moduledoc "Merge policy visibility for the local control CLI."

  @spec print() :: :ok
  def print do
    policy = Aiur.MergePolicy.current()
    watch = if policy.main_watch.enabled, do: "on(#{policy.main_watch.on_red})", else: "off"
    labels = if policy.ci == "wait" and policy.full_ci_labels == ["main-fix"], do: "", else: " full_ci=[#{Enum.join(policy.full_ci_labels, ",")}]"
    IO.puts("MERGE POLICY ci=#{policy.ci} local_tests=#{policy.local_tests}#{labels} main_watch=#{watch}")
  end
end
