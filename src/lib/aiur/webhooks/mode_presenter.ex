defmodule Aiur.Webhooks.ModePresenter do
  @moduledoc """
  Operator-facing view of per-repo delivery mode.

  An operator debugging "why is this repo slow / quiet" needs three facts per
  repo and they are all here: which mode is active, when the last verified
  delivery arrived, and — when the repo is polling — *which* of the three
  reasons applies. "Configured but never delivered" and "delivered, then went
  silent" look identical from the outside and need completely different fixes,
  so the presenter never collapses them into one "not working" state.

  This is the shape the quota-meter surface renders; it holds no markup so the
  same rows serve the dashboard, the CLI, and tests.
  """

  alias Aiur.Webhooks
  alias Aiur.Webhooks.DeliveryMode

  @type row :: %{
          repo: String.t(),
          transport: DeliveryMode.transport(),
          state: DeliveryMode.state(),
          mode_label: String.t(),
          last_delivery_at: DateTime.t() | nil,
          last_delivery_label: String.t(),
          last_activity_at: DateTime.t() | nil,
          last_activity_label: String.t(),
          ever_delivered?: boolean(),
          polling_reason: DeliveryMode.polling_reason(),
          reason_label: String.t() | nil,
          delivery_count: non_neg_integer()
        }

  @doc "One row per known repo, ordered by repo name."
  @spec rows(keyword()) :: [row()]
  def rows(opts \\ []) do
    opts
    |> Keyword.get_lazy(:modes, fn -> Webhooks.list(opts) end)
    |> Enum.sort_by(& &1.repo)
    |> Enum.map(&row/1)
  end

  @doc "The operator row for a single mode struct."
  @spec row(DeliveryMode.t()) :: row()
  def row(%DeliveryMode{} = mode) do
    reason = DeliveryMode.polling_reason(mode)

    %{
      repo: mode.repo,
      transport: DeliveryMode.transport(mode),
      state: mode.state,
      mode_label: mode_label(mode.state),
      last_delivery_at: mode.last_delivery_at,
      last_delivery_label: last_delivery_label(mode.last_delivery_at),
      last_activity_at: mode.last_activity_at,
      last_activity_label: last_delivery_label(mode.last_activity_at),
      ever_delivered?: mode.delivery_count > 0,
      polling_reason: reason,
      reason_label: reason_label(reason),
      delivery_count: mode.delivery_count
    }
  end

  @doc "Human label for a polling reason, or `nil` when webhook-backed."
  @spec reason_label(DeliveryMode.polling_reason()) :: String.t() | nil
  def reason_label(nil), do: nil
  def reason_label(:never_configured), do: "no webhook configured"
  def reason_label(:configured_unproven), do: "webhook configured but never delivered"
  def reason_label(:degraded_from_silence), do: "degraded — deliveries went silent"

  defp mode_label(:webhook_backed), do: "webhook"
  defp mode_label(_state), do: "polling"

  defp last_delivery_label(nil), do: "never"
  defp last_delivery_label(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
