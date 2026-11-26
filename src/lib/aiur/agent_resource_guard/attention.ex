defmodule Aiur.AgentResourceGuard.Attention do
  @moduledoc false

  require Logger

  @doc false
  @spec reconcile(keyword()) :: :ok
  def reconcile(opts) do
    active_attentions_fun = Keyword.get(opts, :active_attentions_fun, &Aiur.Signal.active_attention_alerts/0)
    alert_fun = Keyword.get(opts, :alert_fun, &Aiur.Signal.alert/2)
    process_info_fun = Keyword.fetch!(opts, :process_info_fun)

    active_attentions_fun.()
    |> Enum.each(fn
      %{"topic" => "ticket." <> _ = topic, "reason" => reason} when is_binary(reason) ->
        case {attention_ticket(topic), reported_pids(reason)} do
          {ticket, pids} when is_binary(ticket) and is_list(pids) ->
            live_pids = Enum.filter(pids, &(process_info_fun.(&1) != nil))
            update_attention(alert_fun, topic, ticket, reason, pids, live_pids)

          _other ->
            :ok
        end

      _other ->
        :ok
    end)

    :ok
  rescue
    error -> Logger.warning("agent_resource_guard attention_reconcile_failed error=#{inspect(error)}")
  end

  defp update_attention(alert_fun, topic, ticket, _reason, _pids, []) do
    alert_fun.(topic <> ".resolved",
      issue: ticket,
      message: "Synthetic load alert resolved; no reported processes are still running.",
      reason: "All reported synthetic load processes have exited.",
      needs_attention: false,
      severity: "info"
    )
  end

  defp update_attention(_alert_fun, _topic, _ticket, _reason, pids, pids), do: :ok

  defp update_attention(alert_fun, topic, ticket, reason, _pids, live_pids) do
    alert_fun.(topic,
      issue: ticket,
      message: "Synthetic load remains active; live process(es): #{inspect(live_pids)}",
      reason: update_reported_pids(reason, live_pids),
      needs_attention: true,
      severity: "warning"
    )
  end

  defp attention_ticket("ticket." <> rest) do
    case String.split(rest, ".agent.attention.synthetic-load", parts: 2) do
      [ticket, ""] when ticket != "" -> ticket
      _other -> nil
    end
  end

  defp reported_pids(reason) do
    case Regex.run(~r/\breported=\[(\d*(?:,\s*\d+)*)\]/, reason, capture: :all_but_first) do
      [""] -> []
      [pids] -> pids |> String.split(",", trim: true) |> Enum.map(&(String.trim(&1) |> String.to_integer()))
      _other -> nil
    end
  end

  defp update_reported_pids(reason, pids) do
    reason = Regex.replace(~r/\bkilled=\[\d*(?:,\s*\d+)*\]/, reason, "killed=[]")
    Regex.replace(~r/\breported=\[\d*(?:,\s*\d+)*\]/, reason, "reported=#{inspect(pids)}")
  end
end
