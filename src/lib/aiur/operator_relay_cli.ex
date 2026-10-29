defmodule Aiur.OperatorRelayCLI do
  @moduledoc "Records an operator's already-given answer with explicit relay attribution."

  alias Aiur.Commands

  @spec answer(keyword(), keyword()) :: 0 | 1 | 64
  def answer(params, deps \\ []) do
    with {:ok, payload, actor} <- normalize(params, deps),
         {:ok, result} <- record(params, payload, actor, deps) do
      IO.puts("aiur: answered by operator, relayed by #{actor.id}: Command #{params[:decision_id]} (#{result.status})")
      0
    else
      {:usage, reason} -> error(deps, reason, 64)
      {:error, reason} -> error(deps, error_detail(reason), 1)
    end
  end

  defp normalize(params, deps) do
    with :ok <- required_fields(params),
         {:ok, expected_version} <- expected_version(params, deps),
         idempotency_key <- idempotency_key(params) do
      {:ok,
       %{
         expected_version: expected_version,
         idempotency_key: idempotency_key,
         option_id: params[:option_id],
         custom_response: params[:custom_response],
         operator_quote: params[:quote],
         relayed_by: params[:relayed_by],
         rationale: "Operator answer relayed by #{params[:relayed_by]}"
       }, %{kind: :operator_relayed, id: params[:relayed_by]}}
    end
  end

  defp expected_version(params, deps) do
    if Keyword.get(params, :auto_current) == true do
      fetch_current_version(Keyword.fetch!(params, :decision_id), Keyword.get(deps, :decision_store, Commands.default_store()))
    else
      case Keyword.get(params, :expected_version) do
        version when is_integer(version) and version > 0 -> {:ok, version}
        _invalid -> {:usage, "--expected-version must be a positive integer"}
      end
    end
  end

  defp fetch_current_version(decision_id, store) do
    case Commands.get(decision_id, store: store) do
      {:ok, %{decision: %{version: version}}} when is_integer(version) and version > 0 -> {:ok, version}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_decision_version}
    end
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  defp idempotency_key(params) do
    case {Keyword.get(params, :auto_current), Keyword.get(params, :idempotency_key)} do
      {true, nil} -> "cli_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      {_auto, key} -> key
    end
  end

  defp required_fields(params) do
    required = [:decision_id, :quote, :relayed_by] ++ if(Keyword.get(params, :auto_current) == true, do: [], else: [:idempotency_key])

    case Enum.find(required, fn key ->
           value = params[key]
           not is_binary(value) or String.trim(value) == ""
         end) do
      nil -> :ok
      key -> {:usage, "--#{key |> Atom.to_string() |> String.replace("_", "-")} is required"}
    end
  end

  defp record(params, payload, actor, deps) do
    operation = if params[:supersede] == true, do: :override, else: :answer
    args = [params[:decision_id], payload, [actor: actor]]
    args = if Keyword.has_key?(deps, :decision_store), do: args ++ [deps[:decision_store]], else: args
    apply(Commands, operation, args)
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  defp error_detail({:answer_invalid, {:operator_relay, :disabled}}),
    do: "recording is disabled; the operator must enable executor.relay_operator_answers"

  defp error_detail({:conflict, {:direct_operator_answer, _action_id}}),
    do: "the operator answered this Command directly; a relayed answer cannot replace it"

  defp error_detail({:answer_invalid, :relay_on_executor_command}),
    do: "this Command was raised by the Executor; the operator must answer it on a surface they log in to (dashboard, Stream Deck or phone)"

  defp error_detail(reason), do: "cannot record answer (#{inspect(reason)})"

  defp error(deps, reason, code) do
    Keyword.get(deps, :error_fun, &IO.puts(:stderr, &1)).("aiur: operator-relay-answer #{reason}")
    code
  end
end
