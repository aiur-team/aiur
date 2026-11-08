defmodule Aiur.ExecutorCommandAck do
  @moduledoc false
  require Logger

  alias Aiur.Commands

  @spec ack(keyword(), keyword()) :: 0 | 1 | 64
  def ack(params, deps) when is_list(params) do
    id = Keyword.get(params, :decision_id)
    executor = Keyword.get(params, :executor_id, "aiur-cli")

    with :ok <- validate_id(id),
         :ok <- validate_executor(executor) do
      print_result(record(id, String.trim(executor), :explicit, deps), id, deps)
    else
      {:usage, message} -> error(deps, message, 64)
    end
  end

  def ack(_params, deps), do: error(deps, "executor-ack expects command options", 64)

  defp validate_id(id) do
    if is_binary(id) and Regex.match?(~r/\Adec_[0-9a-f]{16}\z/, id),
      do: :ok,
      else: {:usage, "executor-ack expects a decision ID (dec_ followed by 16 lowercase hex characters)"}
  end

  defp validate_executor(executor) do
    if is_binary(executor) and String.trim(executor) != "" and byte_size(executor) <= 256,
      do: :ok,
      else: {:usage, "executor-ack --executor-id must contain 1–256 bytes"}
  end

  defp print_result({:ok, %{status: status}}, id, _deps) do
    verb = if status == :duplicate, do: "already acknowledged", else: "acknowledged"
    IO.puts("#{verb} #{id}")
    0
  end

  defp print_result({:error, :not_found}, id, deps), do: error(deps, "could not find decision #{id}", 1)
  defp print_result({:error, reason}, id, deps), do: error(deps, "failed to acknowledge Command #{id} (#{inspect(reason)})", 1)

  @spec implicit(map(), atom(), keyword()) :: :ok
  def implicit(normalized, via, deps) do
    case record(normalized.decision_id, normalized.executor_id, via, deps) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("Executor acknowledgement failed decision_id=#{normalized.decision_id} via=#{via} reason=#{inspect(reason)}")
    end
  end

  defp record(id, executor, via, deps) do
    writer = Keyword.get(deps, :record_fact_fun, &Commands.record_command_fact/4)
    now = Keyword.get(deps, :now, DateTime.utc_now())
    writer.(id, :executor_acknowledged, %{executor_id: executor, via: via, at: now}, server: Keyword.get(deps, :decision_store, Commands.default_store()))
  rescue
    error -> {:error, {:store_unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  defp error(deps, message, status) do
    Keyword.get(deps, :error_fun, &IO.puts(:stderr, &1)).("aiur: #{message}")
    status
  end
end
