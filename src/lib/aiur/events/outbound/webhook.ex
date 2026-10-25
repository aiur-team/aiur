defmodule Aiur.Events.Outbound.Webhook do
  @moduledoc "Signed Standard Webhooks delivery handler for the outbound event queue."
  # aiur:event-bus-boundary-member

  @behaviour Aiur.Events.DurableConsumer.Handler

  require Logger

  @spec new!(keyword()) :: map()
  def new!(opts) do
    %{
      url: Keyword.fetch!(opts, :url),
      signing_key: opts |> Keyword.fetch!(:secret) |> decode_secret!(),
      subject_id: Keyword.get(opts, :subject_id),
      request_timeout_ms: Keyword.fetch!(opts, :request_timeout_ms),
      request_fun: Keyword.get(opts, :request_fun, &Req.post/1),
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

    request = [
      url: state.url,
      body: body,
      headers: [
        {"content-type", "application/json"},
        {"webhook-id", event_id},
        {"webhook-timestamp", timestamp},
        {"webhook-signature", signature}
      ],
      receive_timeout: state.request_timeout_ms,
      connect_options: [timeout: state.request_timeout_ms],
      retry: false,
      redirect: false
    ]

    case state.request_fun.(request) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> {:ok, state}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, _reason} -> {:error, :request_failed}
      _other -> {:error, :invalid_transport_result}
    end
  rescue
    _error -> {:error, :request_failed}
  end

  defp deliver(_event, _state), do: {:error, :invalid_event_id}

  defp subscribed?(_event, nil), do: true

  defp subscribed?(event, subject_id) do
    event["ticket_id"] == subject_id or event["job_id"] == subject_id
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
end
