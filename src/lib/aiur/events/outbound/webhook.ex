defmodule Aiur.Events.Outbound.Webhook do
  @moduledoc "Signed Standard Webhooks delivery handler for the outbound event queue."
  # aiur:event-bus-boundary-member

  @behaviour Aiur.Events.DurableConsumer.Handler

  require Logger

  alias Aiur.Config.WebhookDestination

  @spec new!(keyword()) :: map()
  def new!(opts) do
    %{
      url: Keyword.fetch!(opts, :url),
      signing_key: opts |> Keyword.fetch!(:secret) |> decode_secret!(),
      subject_id: Keyword.get(opts, :subject_id),
      allow_private_destinations: Keyword.get(opts, :allow_private_destinations, false),
      request_timeout_ms: Keyword.fetch!(opts, :request_timeout_ms),
      request_fun: Keyword.get(opts, :request_fun, &Req.post/1),
      resolve_fun: Keyword.get(opts, :resolve_fun, &WebhookDestination.resolve/2),
      alert_fun: Keyword.get(opts, :alert_fun, &ignore_alert/2),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)
    }
  end

  @spec sign(String.t(), String.t(), integer(), binary()) :: String.t()
  def sign(secret, webhook_id, timestamp, body) do
    secret
    |> decode_secret!()
    |> signature(webhook_id, timestamp, body)
  end

  @impl true
  def handle_record(%{"event" => event}, state) when is_map(event) do
    if subscribed?(event, state.subject_id) do
      deliver(event, state)
    else
      {:ok, state}
    end
  end

  def handle_record(_record, _state), do: {:error, :invalid_outbound_record}

  @impl true
  def handle_reset(oldest, state) do
    Logger.warning("outbound webhook delivery cursor reset to available position #{oldest}")
    {:ok, state}
  end

  @impl true
  def handle_unavailable(_reason, state) do
    Logger.warning("outbound webhook delivery queue is temporarily unavailable")
    {:ok, state}
  end

  defp deliver(%{"event_id" => event_id} = event, state) when is_binary(event_id) and event_id != "" do
    body = Jason.encode!(event)
    timestamp = state.clock.() |> DateTime.to_unix() |> Integer.to_string()
    signature = signature(state.signing_key, event_id, String.to_integer(timestamp), body)

    case state.resolve_fun.(state.url, state.allow_private_destinations) do
      {:ok, pinned_url, hostname} ->
        request = [
          url: pinned_url,
          body: body,
          headers: [
            {"content-type", "application/json"},
            {"webhook-id", event_id},
            {"webhook-timestamp", timestamp},
            {"webhook-signature", signature}
          ],
          receive_timeout: state.request_timeout_ms,
          connect_options: [timeout: state.request_timeout_ms, hostname: hostname],
          retry: false,
          redirect: false
        ]

        handle_response(state.request_fun.(request), event_id, state)

      {:error, _reason} ->
        {:error, :destination_unavailable}
    end
  rescue
    _error -> {:error, :request_failed}
  end

  defp deliver(_event, _state), do: {:error, :invalid_event_id}

  defp subscribed?(_event, nil), do: true

  defp subscribed?(event, subject_id) do
    event["ticket_id"] == subject_id or event["job_id"] == subject_id
  end

  defp handle_response({:ok, %Req.Response{status: status}}, _event_id, state) when status in 200..299,
    do: {:ok, state}

  defp handle_response({:ok, %Req.Response{status: status}}, _event_id, _state) when status in [408, 429],
    do: {:error, {:http_status, status}}

  defp handle_response({:ok, %Req.Response{status: status}}, event_id, state) when status in 400..499 do
    alert_permanent_failure(state.alert_fun, status, event_id)
    {:discard, {:http_status, status}, state}
  end

  defp handle_response({:ok, %Req.Response{status: status}}, _event_id, _state),
    do: {:error, {:http_status, status}}

  defp handle_response({:error, _reason}, _event_id, _state), do: {:error, :request_failed}
  defp handle_response(_other, _event_id, _state), do: {:error, :invalid_transport_result}

  defp alert_permanent_failure(alert_fun, status, event_id) do
    message = "Outbound webhook event #{event_id} was discarded after permanent HTTP #{status}."

    _ =
      alert_fun.("system.outbound_events.delivery.permanent_failure",
        message: message,
        reason: message,
        needs_attention: true,
        severity: "warning"
      )

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp signature(key, webhook_id, timestamp, body) do
    payload = "#{webhook_id}.#{timestamp}.#{body}"
    encoded = :crypto.mac(:hmac, :sha256, key, payload) |> Base.encode64()
    "v1,#{encoded}"
  end

  defp decode_secret!("whsec_" <> encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == 32 -> key
      _invalid -> raise ArgumentError, "outbound webhook secret must encode exactly 32 bytes"
    end
  end

  defp decode_secret!(_secret), do: raise(ArgumentError, "outbound webhook secret must use the whsec_ prefix")

  defp ignore_alert(_topic, _opts), do: :ok
end
