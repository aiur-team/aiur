defmodule Aiur.ExecutorCommandCLI do
  @moduledoc false

  alias Aiur.{DecisionStore, ExecutorCommandAttention}

  @default_executor_id "aiur-cli"

  @spec answer(keyword(), keyword()) :: 0 | 1 | 64
  def answer(params, deps \\ [])

  def answer(params, deps) when is_list(params) and is_list(deps) do
    with {:ok, normalized} <- normalize_answer(params),
         {:ok, result} <- call_answer(normalized, deps) do
      IO.puts(
        "aiur: Executor #{normalized.executor_id} answered Command #{normalized.decision_id} " <>
          "(#{Map.get(result, :status, :accepted)})"
      )

      0
    else
      {:usage, message} -> usage_error(message, deps)
      {:error, reason} -> command_error("answer", reason, deps)
    end
  end

  def answer(_params, deps), do: usage_error("answer expects command options", deps)

  @spec escalate(keyword(), keyword()) :: 0 | 1 | 64
  def escalate(params, deps \\ [])

  def escalate(params, deps) when is_list(params) and is_list(deps) do
    with {:ok, normalized} <- normalize_escalation(params),
         {:ok, result} <- call_escalation(normalized, deps),
         status <- Map.get(result, :status, :opened) do
      IO.puts(escalation_message(normalized.decision_id, status))
      0
    else
      {:usage, message} -> usage_error(message, deps)
      {:error, reason} -> command_error("escalate", reason, deps)
    end
  end

  def escalate(_params, deps), do: usage_error("escalate expects command options", deps)

  @doc false
  @spec escalation_topic(String.t(), String.t()) :: String.t()
  defdelegate escalation_topic(decision_id, ticket_id), to: ExecutorCommandAttention, as: :topic

  @doc false
  @spec escalation_resolution_topic(String.t(), String.t()) :: String.t()
  def escalation_resolution_topic(decision_id, ticket_id),
    do: escalation_topic(decision_id, ticket_id) <> ".resolved"

  defp normalize_answer(params) do
    with {:ok, decision_id} <- present(params, :decision_id),
         {:ok, expected_version} <- positive_integer(params, :expected_version),
         {:ok, rationale} <- present(params, :rationale),
         {:ok, idempotency_key} <- present(params, :idempotency_key),
         {:ok, executor_id} <- optional_present(params, :executor_id, @default_executor_id),
         {:ok, answer} <- one_answer(params) do
      {:ok,
       %{
         decision_id: decision_id,
         expected_version: expected_version,
         rationale: rationale,
         idempotency_key: idempotency_key,
         executor_id: executor_id,
         answer: answer
       }}
    end
  end

  defp normalize_escalation(params) do
    with {:ok, decision_id} <- present(params, :decision_id),
         {:ok, expected_version} <- positive_integer(params, :expected_version),
         {:ok, reason} <- present(params, :reason),
         {:ok, executor_id} <- optional_present(params, :executor_id, @default_executor_id) do
      {:ok,
       %{
         decision_id: decision_id,
         expected_version: expected_version,
         reason: reason,
         executor_id: executor_id
       }}
    end
  end

  defp one_answer(params) do
    option_id = trimmed(Keyword.get(params, :option_id))
    custom_response = trimmed(Keyword.get(params, :custom_response))

    case {option_id, custom_response} do
      {option_id, nil} when is_binary(option_id) -> {:ok, %{"option_id" => option_id}}
      {nil, custom_response} when is_binary(custom_response) -> {:ok, %{"custom_response" => custom_response}}
      _ -> {:usage, "answer requires exactly one of --option or --custom-response"}
    end
  end

  defp call_answer(normalized, deps) do
    payload =
      normalized.answer
      |> Map.put("expected_version", normalized.expected_version)
      |> Map.put("rationale", normalized.rationale)
      |> Map.put("idempotency_key", normalized.idempotency_key)

    answer_fun =
      Keyword.get(deps, :answer_fun, fn decision_id, answer_payload, opts, store ->
        DecisionStore.answer(decision_id, answer_payload, opts, store)
      end)

    store = Keyword.get(deps, :decision_store, DecisionStore)
    answer_fun.(normalized.decision_id, payload, [actor: %{kind: :executor, id: normalized.executor_id}], store)
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  defp call_escalation(normalized, deps) do
    payload = %{
      expected_version: normalized.expected_version,
      executor_id: normalized.executor_id,
      reason: normalized.reason
    }

    escalate_fun =
      Keyword.get(deps, :escalate_fun, fn decision_id, escalation_payload, store ->
        DecisionStore.escalate_executor_command(decision_id, escalation_payload, store)
      end)

    escalate_fun.(
      normalized.decision_id,
      payload,
      Keyword.get(deps, :decision_store, DecisionStore)
    )
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  defp escalation_message(decision_id, :opened), do: "aiur: escalated Command #{decision_id} to the operator"
  defp escalation_message(decision_id, :already_open), do: "aiur: Command #{decision_id} is already escalated to the operator"

  defp present(params, key) do
    case trimmed(Keyword.get(params, key)) do
      nil -> {:usage, "#{cli_flag(key)} is required"}
      value -> {:ok, value}
    end
  end

  defp optional_present(params, key, default) do
    case Keyword.fetch(params, key) do
      :error -> {:ok, default}
      {:ok, value} -> present([{key, value}], key)
    end
  end

  defp positive_integer(params, key) do
    case Keyword.get(params, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:usage, "#{cli_flag(key)} must be a positive integer"}
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp trimmed(_value), do: nil

  defp usage_error(message, deps) do
    write_error(deps, "aiur: executor command #{message}")
    64
  end

  defp command_error(action, {:stale_version, expected, current}, deps) do
    write_error(deps, "aiur: cannot #{action} Command: stale version #{expected}; current version is #{inspect(current)}")
    1
  end

  defp command_error(action, {:conflict, {:stale_version, expected, current}}, deps),
    do: command_error(action, {:stale_version, expected, current}, deps)

  defp command_error(_action, :already_answered, deps) do
    write_error(deps, "aiur: Command already has an answer; revise it in the dashboard")
    1
  end

  defp command_error(action, {:not_open, status}, deps) do
    write_error(deps, "aiur: cannot #{action} Command because it is not open (#{inspect(status)})")
    1
  end

  defp command_error(_action, {:answer_invalid, {:executor_scope, {field, value}}}, deps) do
    write_error(
      deps,
      "aiur: this Command is outside what the Executor may answer directly (#{field}: #{inspect(value)}); " <>
        "run aiur executor-escalate for this decision instead"
    )

    1
  end

  defp command_error("answer", {:answer_invalid, {:idempotency_key, reason}}, deps) do
    write_error(deps, "aiur: cannot answer Command: --idempotency-key is #{invalid_detail(reason)}; retry with a non-empty --idempotency-key")
    1
  end

  defp command_error("answer", {:answer_invalid, {field, reason}}, deps) when field in [:actor, :actor_id, :actor_kind] do
    write_error(
      deps,
      "aiur: cannot answer Command: Executor attribution is #{invalid_detail(reason)}; retry with a non-empty --executor-id or run aiur executor-escalate"
    )

    1
  end

  defp command_error("answer", {:answer_invalid, {:option_id, reason}}, deps) do
    write_error(deps, "aiur: cannot answer Command: --option is #{invalid_detail(reason)}; choose one of the Command's listed option IDs and retry")
    1
  end

  defp command_error("answer", {:answer_invalid, {:response, reason}}, deps) do
    write_error(deps, "aiur: cannot answer Command: response is #{invalid_detail(reason)}; retry with exactly one of --option or --custom-response")
    1
  end

  defp command_error("answer", {:answer_invalid, {field, reason}}, deps)
       when field in [:custom_response, :expected_version, :rationale] do
    write_error(deps, "aiur: cannot answer Command: #{cli_flag(field)} is #{invalid_detail(reason)}; correct the flag and retry")
    1
  end

  defp command_error("answer", {:answer_invalid, {field, reason}}, deps) when is_atom(field) do
    write_error(deps, "aiur: cannot answer Command: answer field #{field} is #{invalid_detail(reason)}; correct the answer and retry")
    1
  end

  defp command_error(action, reason, deps) do
    write_error(deps, "aiur: failed to #{action} Command (#{inspect(reason)})")
    1
  end

  defp write_error(deps, message) when is_list(deps) do
    error_fun = Keyword.get(deps, :error_fun, &default_error/1)
    error_fun.(message)
  end

  defp write_error(_deps, message), do: default_error(message)

  defp default_error(message), do: IO.puts(:stderr, message)

  defp cli_flag(key), do: "--" <> (key |> Atom.to_string() |> String.replace("_", "-"))

  defp invalid_detail(:missing), do: "missing"
  defp invalid_detail(:invalid), do: "invalid"
  defp invalid_detail(reason), do: "invalid (#{inspect(reason)})"
end
