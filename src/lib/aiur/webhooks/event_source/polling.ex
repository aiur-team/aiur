defmodule Aiur.Webhooks.EventSource.Polling do
  @moduledoc """
  Full-rate polling delivery — the complete, supported, unchanged default.

  A repo served by this module behaves exactly as every repo did before webhook
  support existed: same normalization, same topics, same intervals. Webhook
  support is not allowed to make this path slower, weaker, or less tested.
  """

  @behaviour Aiur.Webhooks.EventSource

  alias Aiur.Webhooks.EventSource

  @impl true
  def deliver(repo, event, opts) when is_binary(repo) and is_map(event) do
    EventSource.publish(event, opts)
  end
end
