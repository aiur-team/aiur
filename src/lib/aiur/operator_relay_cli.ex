defmodule Aiur.OperatorRelayCLI do
  @moduledoc "Records an operator's already-given answer with explicit relay attribution."

  alias Aiur.DecisionStore

  @spec answer(keyword(), keyword()) :: 0 | 1 | 64
  def answer(params, deps \\ []) do
    with {:ok, payload, actor} <- normalize(params),
         {:ok, result} <- record(params, payload, actor, deps) do
      IO.puts("aiur: answered by operator, relayed by #{actor.id}: Command #{params[:decision_id]} (#{result.status})")
      0
    else
      {:usage, reason} -> error(deps, reason, 64)
      {:error, reason} -> error(deps, error_detail(reason), 1)
    end
  end

  defp normalize(params) do
    with :ok <- required_fields(params),
         true <- (is_integer(params[:expected_version]) and params[:expected_version] > 0) or {:usage, "--expected-version must be a positive integer"} do
      {:ok,
       %{
         expected_version: params[:expected_version],
         idempotency_key: params[:idempotency_key],
         option_id: params[:option_id],
         custom_response: params[:custom_response],
         operator_quote: params[:quote],
         relayed_by: params[:relayed_by],
         rationale: "Operator answer relayed by #{params[:relayed_by]}"
       }, %{kind: :operator_relayed, id: params[:relayed_by]}}
    end
  end

  defp required_fields(params) do
    case Enum.find([:decision_id, :quote, :relayed_by, :idempotency_key], fn key ->
           value = params[key]
           not is_binary(value) or String.trim(value) == ""
         end) do
      nil -> :ok
      key -> {:usage, "--#{key |> Atom.to_string() |> String.replace("_", "-")} is required"}
    end
  end

  defp record(params, payload, actor, deps) do
    store = Keyword.get(deps, :decision_store, DecisionStore)

    if params[:supersede] == true,
      do: DecisionStore.supersede(params[:decision_id], payload, [actor: actor], store),
      else: DecisionStore.answer(params[:decision_id], payload, [actor: actor], store)
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  defp error_detail({:answer_invalid, {:operator_relay, :disabled}}),
    do: "recording is disabled; the operator must enable executor.relay_operator_answers"

  defp error_detail(reason), do: "cannot record answer (#{inspect(reason)})"

  defp error(deps, reason, code) do
    Keyword.get(deps, :error_fun, &IO.puts(:stderr, &1)).("aiur: operator-relay-answer #{reason}")
    code
  end
end
