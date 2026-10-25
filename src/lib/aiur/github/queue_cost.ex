defmodule Aiur.GitHub.QueueCost do
  @moduledoc "Attributes queue transition HTTP requests without changing tracker interfaces."

  @spec tag(map()) :: map()
  def tag(request) do
    if Process.get(:aiur_ticket_writer) == :build_queue do
      path = URI.parse(request.url).path || ""

      caller =
        if request.method in [:post, :delete] and Regex.match?(~r{/issues/\d+/labels(?:/|$)}, path),
          do: "build_queue_label_#{request.method}",
          else: "build_queue_write_observe"

      Map.put(request, :caller, caller)
    else
      request
    end
  end
end
