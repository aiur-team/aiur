defmodule Aiur.ExecutorCommandClaim do
  @moduledoc false

  alias Aiur.Commands

  @default_ttl_s 1800

  @spec claim(keyword(), keyword()) :: 0 | 1 | 64
  def claim(params, deps \\ []), do: run(:claim, params, deps)

  @spec release(keyword(), keyword()) :: 0 | 1 | 64
  def release(params, deps \\ []), do: run(:release, params, deps)

  defp run(action, params, deps) do
    id = Keyword.get(params, :decision_id)
    executor = Keyword.get(params, :executor_id)
    ttl = Keyword.get(params, :ttl_s, @default_ttl_s)

    cond do
      not (is_binary(id) and Regex.match?(~r/\Adec_[0-9a-f]{16}\z/, id)) -> usage(deps, "expects a decision ID (dec_ followed by 16 lowercase hex characters)")
      not (is_binary(executor) and Regex.match?(~r/\A[A-Za-z0-9._-]{1,256}\z/, executor)) -> usage(deps, "requires --as <executor> ([A-Za-z0-9._-])")
      executor == "aiur-cli" -> usage(deps, "--as aiur-cli is the shared default and cannot own a claim; name this Executor")
      not (is_integer(ttl) and ttl > 0) -> usage(deps, "--ttl must be a positive number of seconds")
      true -> report(action, perform(action, id, executor, ttl, deps), id, deps)
    end
  end

  defp perform(action, id, executor, ttl, deps) do
    now = Keyword.get(deps, :now, DateTime.utc_now())
    store = Keyword.get(deps, :decision_store, Commands.default_store())
    writer = Keyword.get(deps, :record_fact_fun, &Commands.record_command_fact/4)

    case action do
      :claim -> writer.(id, :executor_claimed, %{executor_id: executor, at: now, expires_at: DateTime.add(now, ttl, :second)}, server: store)
      :release -> writer.(id, :executor_claim_released, %{executor_id: executor, reason: :released, at: now}, server: store)
    end
  rescue
    error -> {:error, {:store_unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  defp report(action, {:error, {:invalid_transition, reason}}, id, deps), do: report(action, {:error, reason}, id, deps)

  defp report(action, {:ok, _result}, id, _deps) do
    IO.puts("#{if action == :claim, do: "claimed", else: "released"} #{id}")
    0
  end

  defp report(_action, {:error, {:claimed, owner, expires_at}}, id, deps),
    do: fail(deps, "Command #{id} is claimed by #{owner} until #{DateTime.to_iso8601(expires_at)}", 1)

  defp report(_action, {:error, :not_claimed}, id, deps), do: fail(deps, "Command #{id} has no live claim", 1)
  defp report(_action, {:error, :not_found}, id, deps), do: fail(deps, "could not find decision #{id}", 1)
  defp report(_action, {:error, reason}, id, deps), do: fail(deps, "failed to update claim on Command #{id} (#{inspect(reason)})", 1)

  defp usage(deps, message), do: fail(deps, "executor-claim-decision #{message}", 64)

  defp fail(deps, message, status) do
    Keyword.get(deps, :error_fun, &IO.puts(:stderr, &1)).("aiur: #{message}")
    status
  end
end
