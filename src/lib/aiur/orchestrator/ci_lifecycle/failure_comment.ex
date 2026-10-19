defmodule Aiur.Orchestrator.CiLifecycle.FailureComment do
  @moduledoc """
  Tells the ticket which checks sent it back to rework (#5133).
  """

  alias Aiur.Tracker
  require Logger

  @doc "Posts the failing checks after the rework write; a failed post never undoes the move."
  @spec post(map(), map(), keyword()) :: :ok
  def post(issue, result, opts) do
    create = Keyword.get(opts, :ci_failure_commenter, &Tracker.create_comment/2)
    target = to_string(issue.identifier || issue.id)

    case create.(target, body(result)) do
      :ok -> :ok
      other -> Logger.warning("CI failure comment not posted: issue=#{target} reason=#{inspect(other)}")
    end

    :ok
  end

  @doc false
  @spec body(map()) :: String.t()
  def body(result) do
    checks = result |> Map.get(:failures, []) |> Enum.map_join("\n", &check_line/1)
    "CI failed on PR ##{result[:pr_number]} head `#{result[:head_sha]}`, so this ticket moved to rework.\n\nFailing checks:\n" <> checks
  end

  defp check_line(%{name: name, url: url}) when is_binary(url) and url != "", do: "- [#{name}](#{url})"
  defp check_line(check), do: "- #{Map.get(check, :name, "unnamed check")}"
end
