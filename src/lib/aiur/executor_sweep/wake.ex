defmodule Aiur.ExecutorSweep.Wake do
  @moduledoc false

  @spec publish(map(), GenServer.server()) :: :ok
  def publish(finding, inbox \\ Aiur.ExecutorWakeInbox) do
    ticket = Map.get(finding, :ticket) || Map.get(finding, :issue_number)
    ticket = if is_integer(ticket), do: ticket, else: "executor-sweep-#{fingerprint(finding)}"
    topic = "ticket.#{ticket}.agent.executor-sweep.finding"

    case Aiur.ExecutorWakeProjection.project(%{topic: topic, needs_attention: true, id: nil}) do
      {:ok, record} -> Aiur.ExecutorWakeInbox.enqueue(Map.merge(record, wake_finding(finding)), inbox)
      :ignore -> :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp wake_finding(finding) do
    finding
    |> Map.take([:kind, :priority, :message, :action, :ticket, :issue_number, :pull_request, :head_sha, :failure_class, :failed_checks, :age_ms])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.put("needs_attention", true)
  end

  defp fingerprint(finding) do
    finding
    |> Map.take([:kind, :ticket, :issue_number, :pull_request, :message])
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
