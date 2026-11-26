defmodule Aiur.GitHub.QueueCost do
  @moduledoc "Attributes queue and historical label HTTP requests without changing tracker interfaces."

  @spec tag(map()) :: map()
  def tag(request) do
    path = URI.parse(request.url).path || ""

    case caller(Process.get(:aiur_ticket_writer), request.method, path) do
      nil -> request
      caller -> Map.put(request, :caller, caller)
    end
  end

  defp caller(:build_queue, method, path) do
    if method in [:post, :delete] and Regex.match?(~r{/issues/\d+/labels(?:/|$)}, path),
      do: "build_queue_label_#{method}",
      else: "build_queue_write_observe"
  end

  defp caller(:history_label_backfill, :post, path) do
    cond do
      Regex.match?(~r{/issues/\d+/labels$}, path) -> "history_label_backfill_post"
      Regex.match?(~r{^/repos/[^/]+/[^/]+/labels$}, path) -> "history_label_backfill_ensure"
      true -> nil
    end
  end

  defp caller(_, _, _), do: nil
end
