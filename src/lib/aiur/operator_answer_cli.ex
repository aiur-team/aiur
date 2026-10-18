defmodule Aiur.OperatorAnswerCLI do
  @moduledoc false

  alias Aiur.Commands
  require Logger

  @spec preview(keyword()) :: 0 | 1 | 64
  def preview(opts) when is_list(opts) do
    store = Keyword.get(opts, :decision_store, Commands.default_store())

    with {:ok, normalized} <- normalize(opts),
         {:ok, decision} <- get_decision(normalized.decision_id, store, opts),
         :ok <- human_required(decision),
         {:ok, selected} <- selected_label(decision, normalized) do
      IO.puts("__AIUR_OPERATOR_ANSWER_PREVIEW__")
      IO.puts("Command: #{decision.decision_id}")
      IO.puts("Question: #{single_line(decision.question)}")
      IO.puts("Version: #{decision.version}")
      IO.puts("Selected answer: #{single_line(selected)}")
      IO.puts("__AIUR_EXPECTED_VERSION__:#{decision.version}")
      0
    else
      {:usage, message} ->
        usage_error(message)

      {:error, reason} ->
        IO.puts(:stderr, "aiur: answer preview failed (#{inspect(reason)})")
        1
    end
  end

  def preview(_opts), do: usage_error("answer preview expects command options")

  @spec answer(keyword()) :: 0 | 1 | 64
  def answer(opts) when is_list(opts) do
    store = Keyword.get(opts, :decision_store, Commands.default_store())

    with {:ok, normalized} <- normalize(opts),
         {:ok, decision} <- get_decision(normalized.decision_id, store, opts),
         :ok <- human_required(decision),
         :ok <- expected_version(decision, normalized),
         :ok <- confirmed_id(normalized),
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
    operator_name = Keyword.get(opts, :operator_name_fun, fn -> System.get_env("USER", "unknown") end).()
    operator_id = "cli:" <> if is_binary(operator_name) and operator_name != "", do: operator_name, else: "unknown"
    expected_version = Keyword.get(opts, :expected_version)
    confirmation = present(Keyword.get(opts, :confirmation))
    option_id = present(Keyword.get(opts, :option_id))
    custom_response = present(Keyword.get(opts, :custom_response))

    cond do
      decision_id == nil -> {:usage, "answer expects exactly one decision ID"}
      Keyword.get(opts, :operator) != true -> {:usage, "answer requires --operator"}
      option_id == nil == (custom_response == nil) -> {:usage, "answer requires exactly one of --option or --custom-response"}
      true -> {:ok, %{decision_id: decision_id, option_id: option_id, custom_response: custom_response, operator_id: operator_id, expected_version: expected_version, confirmation: confirmation}}
    end
  end

  defp get_decision(id, store, opts) do
    get_fun = Keyword.get(opts, :get_fun, fn decision_id, server -> Commands.get(decision_id, store: server) end)

    case get_fun.(id, store) do
      {:ok, %{decision: decision}} -> {:ok, decision}
      {:error, reason} -> {:error, reason}
    end
  end

  defp human_required(%{authority: :human_required}), do: :ok
  defp human_required(%{authority: authority}), do: {:error, {:not_human_required, authority}}

  defp expected_version(%{version: version}, %{expected_version: version}) when is_integer(version), do: :ok
  defp expected_version(%{version: version}, %{expected_version: expected}) when is_integer(expected), do: {:error, {:version_changed, expected, version}}
  defp expected_version(_decision, _normalized), do: {:usage, "answer requires a previewed --expected-version"}

  defp confirmed_id(%{decision_id: id, confirmation: id}), do: :ok
  defp confirmed_id(_normalized), do: {:usage, "answer confirmation did not match the decision ID"}

  defp selected_label(%{options: options}, %{option_id: option_id}) when is_list(options) and is_binary(option_id) do
    case Enum.find(options, &(&1.id == option_id)) do
      nil -> {:error, {:unknown_option, option_id}}
      option -> {:ok, option.label}
    end
  end

  defp selected_label(_decision, %{custom_response: response}) when is_binary(response), do: {:ok, "custom response: #{response}"}
  defp selected_label(_decision, _normalized), do: {:error, :invalid_answer}

  defp single_line(value) when is_binary(value), do: String.replace(value, ~r/[\r\n]+/, " ")

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
    result = answer_fun.(decision.decision_id, payload, [actor: %{kind: :operator, id: normalized.operator_id}], store)

    case result do
      {:ok, _} ->
        Logger.info("operator CLI answered Command #{decision.decision_id} actor=#{normalized.operator_id} option=#{normalized.option_id || "custom_response"}")
        result

      other ->
        other
    end
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
