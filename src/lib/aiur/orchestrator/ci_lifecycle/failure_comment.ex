defmodule Aiur.Orchestrator.CiLifecycle.FailureComment do
  @moduledoc """
  Tells the ticket which checks sent it back to rework (#5133), with the first
  error lines each check reported so the worker starts from the failure itself.
  """

  alias Aiur.Tracker
  require Logger

  @excerpt_lines 3

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

  @doc """
  Puts the error lines the failure digest read from each check's annotations
  on the failure as `:error_lines`, and uses them as its `:excerpt` when GitHub
  gave the check no summary of its own.
  """
  @spec with_error_lines(map()) :: map()
  def with_error_lines(%{failures: failures, ci_failure_digest: %{checks: checks}} = result) when is_list(failures) and is_list(checks) do
    errors = Map.new(checks, &{Map.get(&1, :name), Map.get(&1, :errors, [])})
    %{result | failures: Enum.map(failures, &put_error_lines(&1, Map.get(errors, Map.get(&1, :name), [])))}
  end

  def with_error_lines(result), do: result

  defp put_error_lines(failure, [_ | _] = lines) do
    failure = Map.put(failure, :error_lines, lines)
    if blank?(Map.get(failure, :excerpt)), do: Map.put(failure, :excerpt, Enum.join(lines, "\n")), else: failure
  end

  defp put_error_lines(failure, _lines), do: failure

  @doc false
  @spec body(map()) :: String.t()
  def body(result) do
    checks = result |> Map.get(:failures, []) |> Enum.map_join("\n", &(check_line(&1) <> excerpt_lines(&1)))
    "CI failed on PR ##{result[:pr_number]} head `#{result[:head_sha]}`, so this ticket moved to rework.\n\nFailing checks:\n" <> checks
  end

  defp check_line(%{name: name, url: url, pr_caused?: true}) when is_binary(url) and url != "", do: "- [#{name}](#{url}) (new failure on PR head)"
  defp check_line(%{name: name, pr_caused?: true}), do: "- #{name} (new failure on PR head)"
  defp check_line(%{name: name, url: url}) when is_binary(url) and url != "", do: "- [#{name}](#{url})"
  defp check_line(check), do: "- #{Map.get(check, :name, "unnamed check")}"

  defp excerpt_lines(check) do
    case Map.get(check, :error_lines) do
      [_ | _] = lines -> lines |> Enum.take(@excerpt_lines) |> Enum.map_join(&("\n  > " <> &1))
      _ -> ""
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
