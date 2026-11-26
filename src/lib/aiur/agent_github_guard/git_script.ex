defmodule Aiur.AgentGitHubGuard.GitScript do
  @moduledoc """
  Splices the merge-queue push refusal into the agent `git` guard at compile
  time, so the guard stays one installed file while its parts stay small.
  """

  @marker "# @aiur-merge-queue-push-guard@\n"
  @queue_guard_path Path.expand("../../../priv/github_merge_queue_push_guard.sh", __DIR__)
  @external_resource @queue_guard_path
  @queue_guard File.read!(@queue_guard_path)

  @spec compose(String.t()) :: String.t()
  def compose(git_script) when is_binary(git_script), do: String.replace(git_script, @marker, @queue_guard)
end
