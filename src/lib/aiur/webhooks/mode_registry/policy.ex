defmodule Aiur.Webhooks.ModeRegistry.Policy do
  @moduledoc """
  The pure rules `Aiur.Webhooks.ModeRegistry` applies: the canonical repo key,
  how long an observation is remembered, and what each mode transition tells
  the operator. The GenServer keeps the state, the sweep timer and every side
  effect.
  """

  alias Aiur.Webhooks.DeliveryMode

  # GitHub repository names are case-insensitive, and the two pipes that feed
  # this registry disagree on case: a delivery is keyed by the payload's
  # `repository.full_name` (whatever case GitHub sent) while configuration and
  # the poller supply their own. `Normalizer.tracked_repo/2` already downcases
  # *to compare*, which is the codebase acknowledging these strings differ.
  #
  # Without one canonical key the same repository becomes two entries, and they
  # fail in opposite directions: the delivery-cased one is webhook_backed and
  # never sees activity so it can never degrade, while the config-cased one has
  # zero deliveries and accumulating activity so it raises a false
  # `webhook.never_delivered`. Every key crossing this process is therefore
  # normalized here, at the one boundary all of them pass through.
  @spec normalize(String.t()) :: String.t()
  def normalize(repo) when is_binary(repo), do: repo |> String.trim() |> String.downcase()

  # Observation memory only has to outlive the window a replay could span, so
  # it is dropped two full silence thresholds after a resource was last offered.
  # Anything the poller is still re-offering refreshes on every sighting and so
  # never reaches this, which bounds the map to what the fleet is actively
  # looking at rather than everything it has ever seen.
  @spec prune_observed(map(), pos_integer()) :: map()
  def prune_observed(observed, silence_threshold_ms) do
    horizon = System.monotonic_time(:millisecond) - 2 * silence_threshold_ms

    Map.reject(observed, fn {_key, seen_at} -> seen_at < horizon end)
  end

  # The degradation alert names the repo because an operator reading "webhooks
  # degraded" across a multi-repo fleet cannot act on it otherwise, and it
  # carries the evidence that justified it — deliveries seen, when the last one
  # arrived, and the observed activity that proves one was owed. An alert that
  # only says "silent" cannot be told apart from an idle weekend, and an
  # operator who has been shown enough false ones stops reading the true one.
  @spec alert(DeliveryMode.t(), :degraded | :never_delivered | :recovered, pos_integer()) :: {String.t(), String.t(), keyword()}
  def alert(%DeliveryMode{repo: repo} = mode, :degraded, silence_threshold_ms) do
    seconds = div(silence_threshold_ms, 1_000)

    {
      "webhook.degraded",
      "#{repo} delivered nothing for over #{seconds}s while the poller saw activity — reverting to full polling",
      reason:
        "#{repo} had #{mode.delivery_count} verified #{plural(mode.delivery_count, "delivery", "deliveries")}, the last at #{stamp(mode.last_delivery_at)}, " <>
          "but the poller observed repository activity at #{stamp(mode.last_activity_at)} that no delivery carried. " <>
          "Aiur restored full polling for that repo automatically. The webhook worked before, so check ingress reachability first (a public URL that has stopped resolving or a tunnel that is down), then the App install.",
      needs_attention: true,
      severity: "warning"
    }
  end

  # The state an ingress that was never publicly reachable produces. It is
  # distinct from degradation — nothing has ever arrived, so there is no
  # "resumed delivery" to wait for — and distinct from an unconfigured repo,
  # which is a deliberate choice rather than a broken one.
  def alert(%DeliveryMode{repo: repo} = mode, :never_delivered, _silence_threshold_ms) do
    {
      "webhook.never_delivered",
      "#{repo} is configured for webhooks but has never delivered once",
      reason:
        "#{repo} expects webhooks and the poller observed repository activity at #{stamp(mode.last_activity_at)}, " <>
          "yet not one verified delivery has ever arrived for it. This is a setup that has never worked, not one that stopped: " <>
          "Aiur is polling this repo at full rate. Confirm the receiver is reachable from the public internet — a tailnet-only or " <>
          "loopback-bound dashboard cannot receive GitHub deliveries at all — then confirm the App webhook URL and secret.",
      needs_attention: true,
      severity: "warning"
    }
  end

  def alert(%DeliveryMode{repo: repo}, :recovered, _silence_threshold_ms) do
    {
      "webhook.recovered",
      "#{repo} webhook deliveries resumed — back to webhook mode",
      reason: "A verified delivery arrived for #{repo} after degradation. Webhook mode was restored with no operator action.", needs_attention: false, severity: "info"
    }
  end

  defp stamp(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp stamp(_never), do: "never"

  defp plural(1, singular, _plural), do: singular
  defp plural(_count, _singular, plural), do: plural
end
