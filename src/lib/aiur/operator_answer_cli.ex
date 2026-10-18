defmodule Aiur.OperatorAnswerCLI do
  @moduledoc false

  alias Aiur.{Commands, DecisionQuery}

  @spec answer(keyword()) :: 0 | 1 | 64
  def answer(opts) when is_list(opts) do
    store = Keyword.get(opts, :decision_store, Commands.default_store())

    with {:ok, normalized} <- normalize(opts),
         {:ok, decision} <- get_decision(normalized.decision_id, store, opts),
         :ok <- human_required(decision),
         {:ok, result} <- record_answer(decision, normalized, store, opts) do
      IO.puts("aiur: operator #{normalized.operator_id} answered Command #{decision.decision_id} (#{Map.get(result, :status, :accepted)})")
      0
    else
      {:usage, message} ->
        usage_error(message)

      {:error, reason} ->
        IO.puts(:stderr, "aiur: answer failed (#{inspect(reason)})")
        1
    end
  end

  def answer(_opts), do: usage_error("answer expects command options")

  defp normalize(opts) do
    decision_id = present(Keyword.get(opts, :decision_id))
    operator_id = present(Keyword.get(opts, :operator_id, "aiur-cli"))
    option_id = present(Keyword.get(opts, :option_id))
    custom_response = present(Keyword.get(opts, :custom_response))

    cond do
      decision_id == nil -> {:usage, "answer expects exactly one decision ID"}
      Keyword.get(opts, :operator) != true -> {:usage, "answer requires --operator"}
      option_id == nil == (custom_response == nil) -> {:usage, "answer requires exactly one of --option or --custom-response"}
      operator_id == nil -> {:usage, "--operator-id must not be empty"}
      true -> {:ok, %{decision_id: decision_id, option_id: option_id, custom_response: custom_response, operator_id: operator_id}}
    end
  end

  defp get_decision(id, store, opts) do
    get_fun = Keyword.get(opts, :get_fun, fn decision_id, server -> DecisionQuery.get(decision_id, store: server) end)

    case get_fun.(id, store) do
      {:ok, %{decision: decision}} -> {:ok, decision}
      {:error, reason} -> {:error, reason}
    end
  end

  defp human_required(%{authority: :human_required}), do: :ok
  defp human_required(%{authority: authority}), do: {:error, {:not_human_required, authority}}

  defp record_answer(decision, normalized, store, opts) do
    answer =
      if normalized.option_id,
        do: %{"option_id" => normalized.option_id},
        else: %{"custom_response" => normalized.custom_response}

    payload =
      answer
      |> Map.put("expected_version", decision.version)
      |> Map.put("idempotency_key", "cli_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false))

    answer_fun = Keyword.get(opts, :answer_fun, fn id, body, answer_opts, server -> Commands.answer(id, body, answer_opts, server) end)
    answer_fun.(decision.decision_id, payload, [actor: %{kind: :operator, id: normalized.operator_id}], store)
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present(_value), do: nil

  defp usage_error(message) do
    IO.puts(:stderr, "aiur: answer #{message}")
    64
  end
end
