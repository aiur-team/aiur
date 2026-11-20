defmodule AiurWeb.ExecutorVoiceTarget do
  @moduledoc "Executor dictation eligibility from the instance capability registry."

  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(target) do
    report_fun = AiurWeb.EndpointConfig.get(:capabilities_report_fun) || (&Aiur.Capabilities.report/0)
    report = report_fun.()

    case report do
      %{instance: %{instance_id: own}, capabilities: capabilities} when is_binary(own) ->
        if target.instance_id == own,
          do: capability(Map.get(capabilities, "executor.conversation")),
          else: {:error, :target_not_found}

      _ ->
        {:error, :unknown}
    end
  rescue
    _ -> {:error, :unknown}
  catch
    _kind, _reason -> {:error, :unknown}
  end

  defp capability(%{state: state, mode: %{effective: nil}}) when state in [:available, :degraded, "available", "degraded"],
    do: {:error, :target_not_writable}

  defp capability(%{state: state}) when state in [:available, :degraded, "available", "degraded"], do: :ok

  defp capability(%{state: state, reason: reason}) when state in [:unavailable, "unavailable"] and reason in [:executor_absent, "executor_absent"],
    do: {:error, :target_not_found}

  defp capability(%{state: state, reason: reason}) when state in [:unavailable, "unavailable"] and reason in [:executor_not_managed, "executor_not_managed"],
    do: {:error, :target_not_writable}

  defp capability(_), do: {:error, :unknown}
end
