defmodule Aiur.Experiments.AnalysisDispatch do
  @moduledoc false
  alias Aiur.Experiments
  alias Aiur.Experiments.AnalysisTicket

  @spec ticket(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def ticket(request, attrs, deps) do
    cond do
      request["state"] != "open" -> {:ok, request}
      request["ticket"] -> promote(request, deps)
      is_integer(request["next_attempt_ms"]) and request["next_attempt_ms"] > deps.clock.() -> {:error, :ticket_retry_pending}
      true -> attempt(request, attrs, deps)
    end
  end

  defp promote(request, deps) do
    if request["analysis_type"] == "confirmatory" and request["ticket"]["analysis_type"] != "confirmatory" and request["routing_promoted"] != true do
      if (request["promotion_next_attempt_ms"] || 0) > deps.clock.(), do: {:error, :ticket_retry_pending}, else: attempt_promotion(request, deps)
    else
      {:ok, request}
    end
  end

  defp attempt_promotion(request, deps) do
    attempts = (request["promotion_attempts"] || 0) + 1
    fields = %{"promotion_attempts" => attempts, "promotion_next_attempt_ms" => deps.clock.() + backoff(attempts)}

    with {:ok, pending} <- Experiments.update_analysis_dispatch(request["experiment_id"], request["request_id"], fields) do
      promotion_result(deps.promote.(request["ticket"]["number"]), pending, deps)
    end
  end

  defp promotion_result(:ok, request, _deps), do: Experiments.update_analysis_dispatch(request["experiment_id"], request["request_id"], %{"routing_promoted" => true})

  defp promotion_result({:error, _reason} = error, request, deps) do
    if request["promotion_attempts"] == 3, do: deps.alert.(request)
    error
  end

  defp attempt(request, attrs, deps) do
    attempts = (request["dispatch_attempts"] || 0) + 1
    type = if request["ticket_status"] in ["creating", "uncertain"], do: request["dispatched_analysis_type"], else: request["analysis_type"]
    fields = %{"dispatch_requested" => true, "ticket_status" => "creating", "dispatch_attempts" => attempts, "dispatched_analysis_type" => type, "next_attempt_ms" => deps.clock.() + backoff(attempts)}

    fields =
      if request["ticket_status"] in ["creating", "uncertain"], do: fields, else: Map.put(fields, "first_creating_ms", request["first_creating_ms"] || deps.clock.())

    with {:ok, pending} <- Experiments.update_analysis_dispatch(request["experiment_id"], request["request_id"], fields) do
      send_or_reconcile(request["ticket_status"], pending, attrs, deps)
    end
  end

  defp send_or_reconcile(status, request, attrs, deps) when status in ["creating", "uncertain"] do
    case deps.find.(AnalysisTicket.marker(request), lookup_options(request)) do
      {:ok, nil} -> resend(request, attrs, deps)
      {:ok, ticket} -> finish(request, {:ok, ticket}, deps)
      {:error, reason} -> finish(request, {:uncertain, reason}, deps)
    end
  end

  defp send_or_reconcile(_status, request, attrs, deps) do
    with {:ok, pending} <- Experiments.update_analysis_dispatch(request["experiment_id"], request["request_id"], %{"daemon_login" => deps.daemon_account.()}) do
      result =
        case deps.labels.(attrs.labels) do
          :ok -> classify(deps.create.(attrs))
          {:error, reason} -> {:retryable, reason}
        end

      finish(pending, result, deps)
    end
  end

  # The lower bound predates every possible POST. Never advance it on retries.
  defp lookup_options(request) do
    started = request["first_creating_ms"] || requested_ms(request["requested_at"])
    if is_integer(started), do: [since: started |> Kernel.-(300_000) |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()], else: []
  end

  defp requested_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> DateTime.to_unix(at, :millisecond)
      _invalid -> nil
    end
  end

  defp requested_ms(_value), do: nil

  defp resend(request, attrs, deps) do
    fields = %{"dispatched_analysis_type" => request["analysis_type"]}

    with {:ok, pending} <- Experiments.update_analysis_dispatch(request["experiment_id"], request["request_id"], fields) do
      send_or_reconcile(nil, pending, attrs, deps)
    end
  end

  defp classify({:ok, ticket}), do: {:ok, ticket}
  defp classify({:error, {:github, kind, _detail} = reason}) when kind in [:auth, :permission, :rate_limited], do: {:retryable, reason}
  defp classify({:error, {:github, :http, %{status: status}} = reason}) when status in [400, 404, 422], do: {:retryable, reason}
  defp classify({:error, reason}) when reason in [:unsupported, :missing_github_repo, :missing_github_token], do: {:retryable, reason}
  defp classify({:error, reason}), do: {:uncertain, reason}

  defp finish(request, {:ok, ticket}, deps) do
    with {:ok, attached} <- Experiments.attach_analysis_ticket(request["experiment_id"], request["request_id"], Map.put(ticket, "analysis_type", request["dispatched_analysis_type"])),
         do: promote(attached, deps)
  end

  defp finish(request, {status, reason}, deps) do
    with {:ok, _updated} <- Experiments.update_analysis_dispatch(request["experiment_id"], request["request_id"], %{"ticket_status" => to_string(status)}) do
      if request["dispatch_attempts"] == 3, do: deps.alert.(request)
      {:error, reason}
    end
  end

  defp backoff(attempt), do: min(60_000 * Integer.pow(2, min(attempt - 1, 6)), 3_600_000)
end
