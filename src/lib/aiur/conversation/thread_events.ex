defmodule Aiur.Conversation.ThreadEvents do
  @moduledoc "Announces new operator/agent messages in a ticket's worker conversation as `ticket.<id>.agent.thread.changed`."

  require Logger

  alias Aiur.Conversation.Ref
  alias Aiur.Events

  @kinds ~w(message operator_message)

  @doc "One identifier-only publish per appended batch that holds a thread entry. Never raises or exits into the journal."
  @spec appended(Ref.t(), [map()]) :: :ok
  def appended(%Ref{subject: {:worker, %{identifier: id}}}, [_ | _] = entries) when is_binary(id) do
    case Enum.filter(entries, &(&1.kind in @kinds)) do
      [] -> :ok
      thread -> publish(id, %{head_pos: entries |> Enum.map(& &1.pos) |> Enum.max(), kind: List.last(thread).kind})
    end
  end

  def appended(_ref, _entries), do: :ok

  defp publish(id, payload) do
    case Events.publish("ticket.#{id}.agent.thread.changed", payload, issue_number: id) do
      {:error, reason} -> Logger.warning("thread_changed_publish issue_identifier=#{id} error=#{inspect(reason)}")
      _published_or_filtered -> :ok
    end

    :ok
  rescue
    error ->
      Logger.warning("thread_changed_publish issue_identifier=#{id} error=#{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("thread_changed_publish issue_identifier=#{id} exit=#{inspect(reason)}")
      :ok
  end
end
