defmodule Aiur.AgentTools.HistoryExportErrors do
  @moduledoc false

  @spec payload(term()) :: map()
  def payload({:history_unavailable, message}), do: error(:history_unavailable, message)
  def payload(reason), do: error(reason, "History export refused: #{reason}. No rows were handed out.")

  defp error(code, message), do: %{"error" => %{"code" => to_string(code), "message" => message}}
end
