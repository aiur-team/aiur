defmodule Aiur.Orchestrator.StatusCLI.PausedReservations do
  @moduledoc false

  @attention_topic "system.dispatch.paused_reservations"

  @spec print(map(), keyword()) :: :ok
  def print(summary, opts \\ [])

  def print(%{count: count, oldest_age_seconds: age}, opts) when count > 0 and is_integer(age) do
    IO.puts("#{count} slots held by paused agents (oldest #{duration(age)})")

    active? = Keyword.get(opts, :active?, &Aiur.AlertFeed.active_system_attention?/1)
    emit = Keyword.get(opts, :emit, &emit_alert/1)

    if age >= 30 * 60 do
      unless active?.(@attention_topic) do
        emit.(%{
          topic: @attention_topic,
          reason: "#{count} paused agents hold worker slots; oldest reservation is #{duration(age)} old.",
          needs_attention: true,
          severity: "warning"
        })
      end
    else
      if active?.(@attention_topic) do
        emit.(%{
          topic: @attention_topic <> ".resolved",
          reason: "No long-held paused worker reservations remain.",
          needs_attention: false,
          severity: "info"
        })
      end
    end
  end

  def print(_summary, _opts), do: :ok

  defp emit_alert(%{topic: topic} = alert), do: Aiur.Signal.alert(topic, Map.to_list(Map.delete(alert, :topic)))

  defp duration(seconds) when seconds >= 3600, do: "#{div(seconds, 3600)}h"
  defp duration(seconds), do: "#{div(seconds, 60)}m"
end
