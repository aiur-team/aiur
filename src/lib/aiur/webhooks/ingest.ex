defmodule Aiur.Webhooks.Ingest do
  @moduledoc """
  The admission gate a webhook receiver calls before any handler runs.

  One call composes the three defences this subsystem owns, in the order that
  makes each one cheap:

  1. **Delivery id** (`X-GitHub-Delivery`). The same value is reused across
     every retry of one delivery, so a repeat is dropped outright.
  2. **Semantic event key** (`Aiur.Webhooks.EventKey`). Two *different*
     delivery ids can carry the same underlying event; the payload-derived key
     catches what the delivery id cannot.
  3. **Label-state ordering** (`Aiur.Webhooks.LabelState`). Arrival order is
     not event order, so a labeled/unlabeled payload is admitted only when it
     is newer than the last one applied, and it is applied as GitHub's full
     label list rather than as an add/remove delta.

  Handlers must still be idempotent on their own — see the module docs of
  `Aiur.Webhooks.DeliveryLog` for the restart and failure windows these three
  layers deliberately leave open.

  ## Usage

      case Aiur.Webhooks.Ingest.accept(delivery_id, event_name, payload) do
        {:process, admission} -> handle(admission)
        {:drop, reason, meta} -> log_duplicate(reason, meta)
      end

  On `{:process, admission}`, `admission.label_state` is `nil` for events that
  carry no label transition, or a map with the full `labels` list to apply. A
  `refresh_required?: true` label state means the payload's own list cannot be
  trusted for ordering and the issue should be re-read from the API.
  """

  alias Aiur.Webhooks.{DeliveryLog, EventKey, LabelState}

  @type admission :: %{
          delivery_id: String.t() | nil,
          event: String.t(),
          semantic_key: String.t() | nil,
          label_state: nil | %{issue_number: pos_integer(), labels: [String.t()], refresh_required?: boolean()}
        }

  @type drop_reason :: :duplicate_delivery | :duplicate_event | :stale_state | :unusable_payload

  @label_actions ["labeled", "unlabeled"]
  @label_events ["issues", "pull_request"]

  @doc """
  Admits or drops one webhook delivery.

  `opts` accepts `:store` to target a `Aiur.Webhooks.DeliveryLog` other than
  the named default, which is what the tests use.
  """
  @spec accept(term(), term(), term(), keyword()) :: {:process, admission()} | {:drop, drop_reason(), map()}
  def accept(delivery_id, event_name, payload, opts \\ [])

  def accept(delivery_id, event_name, payload, opts) when is_binary(event_name) and is_map(payload) do
    store = Keyword.get(opts, :store, DeliveryLog)

    with :ok <- claim_delivery(delivery_id, store),
         {:ok, semantic_key} <- claim_event(event_name, payload, store),
         {:ok, label_state} <- admit_label_state(event_name, payload, store) do
      {:process,
       %{
         delivery_id: normalized_delivery_id(delivery_id),
         event: event_name,
         semantic_key: semantic_key,
         label_state: label_state
       }}
    end
  end

  def accept(_delivery_id, event_name, _payload, _opts) do
    {:drop, :unusable_payload, %{event: event_name}}
  end

  defp claim_delivery(delivery_id, store) do
    case normalized_delivery_id(delivery_id) do
      nil ->
        :ok

      id ->
        case DeliveryLog.claim(:delivery, id, store) do
          :new -> :ok
          {:duplicate, recorded_at} -> {:drop, :duplicate_delivery, %{delivery_id: id, first_seen_at: recorded_at}}
        end
    end
  end

  defp claim_event(event_name, payload, store) do
    case EventKey.derive(event_name, payload) do
      nil ->
        {:ok, nil}

      key ->
        case DeliveryLog.claim(:event, key, store) do
          :new -> {:ok, key}
          {:duplicate, recorded_at} -> {:drop, :duplicate_event, %{semantic_key: key, first_seen_at: recorded_at}}
        end
    end
  end

  # Only label transitions consult the ordering watermark. Advancing it on
  # every payload would let an unrelated action at the same second mark a real
  # label change as stale.
  defp admit_label_state(event_name, payload, store) do
    if label_transition?(event_name, payload) do
      converge_label_state(payload, store)
    else
      {:ok, nil}
    end
  end

  defp converge_label_state(payload, store) do
    with {:ok, incoming} <- LabelState.derive(payload),
         scope_id when is_binary(scope_id) <- watermark_id(payload, incoming.issue_number) do
      known = DeliveryLog.lookup(:issue_labels, scope_id, store)

      case LabelState.converge(known, incoming) do
        {:apply, state} ->
          DeliveryLog.advance(:issue_labels, scope_id, state.position, store)
          {:ok, label_state(state, false)}

        {:refresh, :ambiguous_timestamp} ->
          {:ok, label_state(incoming, true)}

        {:skip, :stale} ->
          {:drop, :stale_state, %{issue_number: incoming.issue_number, position: incoming.position, applied: known}}
      end
    else
      _ -> {:ok, nil}
    end
  end

  defp label_state(state, refresh_required?) do
    %{issue_number: state.issue_number, labels: state.labels, refresh_required?: refresh_required?}
  end

  defp label_transition?(event_name, payload) do
    event_name in @label_events and Map.get(payload, "action") in @label_actions
  end

  defp watermark_id(payload, issue_number) do
    case payload do
      %{"repository" => %{"full_name" => full_name}} when is_binary(full_name) and full_name != "" ->
        "#{full_name}##{issue_number}"

      _ ->
        nil
    end
  end

  defp normalized_delivery_id(delivery_id) when is_binary(delivery_id) do
    case String.trim(delivery_id) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalized_delivery_id(_delivery_id), do: nil
end
