defmodule Aiur.Webhooks.EventSource.Webhook do
  @moduledoc """
  Webhook delivery — the same normalized publish, plus proof of life.

  Recording the delivery is what promotes a configured repo to webhook-backed
  and what keeps a proven repo out of degradation. It happens *before* the
  publish so a consumer reacting synchronously can never observe the repo as
  silent while it is handling one of that repo's deliveries.

  Verifying the delivery (signature, install, replay window) belongs to the
  receiver upstream of this module. Reaching `deliver/3` means the delivery is
  already trusted — this is the point at which a delivery counts as proof.
  """

  @behaviour Aiur.Webhooks.EventSource

  alias Aiur.Webhooks
  alias Aiur.Webhooks.EventSource

  @impl true
  def deliver(repo, event, opts) when is_binary(repo) and is_map(event) do
    Webhooks.record_delivery(repo, Keyword.take(opts, [:at, :server]))
    EventSource.publish(event, opts)
  end
end
