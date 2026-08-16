defmodule AiurWeb.GithubWebhook.Auth do
  @moduledoc """
  Signature boundary for the GitHub webhook receiver.

  This endpoint is a remote-control surface for the fleet: an unverified
  delivery could inject a "review submitted" or "label changed" event and drive
  agent behaviour. Every request is therefore proven to come from GitHub before
  the controller runs, and every failure mode fails closed.

  The shared secret is read from `AIUR_GITHUB_WEBHOOK_SECRET` on each request so
  an Executor can rotate it without restarting Aiur. When no secret is
  configured the receiver rejects everything and raises a needs-attention alert
  — a misconfigured deployment must never accept unsigned deliveries.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Aiur.Alerts
  alias AiurWeb.GithubWebhook
  alias AiurWeb.GithubWebhook.Signature

  @secret_env "AIUR_GITHUB_WEBHOOK_SECRET"
  @secret_missing_alert "system.github_webhook.secret_missing"
  @secret_missing_alert_window_ms 60_000
  @throttle_key {__MODULE__, :secret_missing_alerted_at}

  # Delivery id and event type are attacker-controlled until verification
  # succeeds, so they are truncated and stripped of control characters before
  # they reach a log line.
  @header_log_limit 100

  @unauthorized_body ~s({"error":{"code":"invalid_signature","message":"Signature verification failed"}})

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case verify(conn) do
      :ok ->
        Logger.info("[github-webhook] accepted #{delivery_context(conn)}")
        conn

      {:error, reason} ->
        Logger.warning("[github-webhook] rejected #{delivery_context(conn)} reason=#{reason}")
        unauthorized(conn)
    end
  end

  @doc "Clears the missing-secret alert throttle. Test support only."
  @spec reset_alert_throttle() :: :ok
  def reset_alert_throttle do
    :persistent_term.erase(@throttle_key)
    :ok
  end

  defp verify(conn) do
    with {:ok, secret} <- configured_secret(conn),
         {:ok, raw_body} <- raw_body(conn) do
      Signature.verify(raw_body, get_req_header(conn, "x-hub-signature-256"), secret)
    end
  end

  # The secret is used verbatim: GitHub signs with exactly the bytes configured
  # on its side, so trimming here would silently key the HMAC off a different
  # secret than the operator set. A blank value is treated as unconfigured.
  defp configured_secret(conn) do
    case System.get_env(@secret_env) do
      secret when is_binary(secret) ->
        if String.trim(secret) == "", do: missing_secret(conn), else: {:ok, secret}

      _unset ->
        missing_secret(conn)
    end
  end

  defp missing_secret(conn) do
    maybe_alert_missing_secret(conn)
    {:error, :secret_not_configured}
  end

  # A rejected delivery is retried by GitHub, so an unthrottled alert would turn
  # a misconfiguration into an alert storm. One alert per minute is enough to
  # make the misconfiguration impossible to miss.
  defp maybe_alert_missing_secret(conn) do
    now = System.monotonic_time(:millisecond)

    if alert_due?(now) do
      :persistent_term.put(@throttle_key, now)

      alert_fun().(@secret_missing_alert,
        message: "GitHub webhook secret is not configured",
        reason: "Rejecting every GitHub webhook delivery until #{@secret_env} is set (#{delivery_context(conn)})",
        needs_attention: true,
        severity: "warning"
      )
    end

    :ok
  end

  defp alert_due?(now) do
    case :persistent_term.get(@throttle_key, nil) do
      nil -> true
      previous -> now - previous >= @secret_missing_alert_window_ms
    end
  end

  defp alert_fun do
    Application.get_env(:aiur, :github_webhook_alert_fun, &Alerts.emit_system/2)
  end

  # The raw body is cached by `AiurWeb.GithubWebhook.BodyReader` while
  # `Plug.Parsers` runs. It is absent when the content type was not parsed at
  # all, in which case there are no bytes we can prove GitHub signed.
  defp raw_body(conn) do
    case Map.fetch(conn.private, GithubWebhook.raw_body_key()) do
      {:ok, raw_body} when is_binary(raw_body) -> {:ok, raw_body}
      _missing -> {:error, :missing_raw_body}
    end
  end

  defp delivery_context(conn) do
    "delivery=#{header_for_log(conn, "x-github-delivery")} event=#{header_for_log(conn, "x-github-event")}"
  end

  defp header_for_log(conn, header) do
    case get_req_header(conn, header) do
      [value | _rest] -> sanitize(value)
      [] -> "unknown"
    end
  end

  # Byte-wise rather than regex-based: truncating an arbitrary header can split
  # a multi-byte sequence, and a `String` operation on the resulting invalid
  # UTF-8 would raise inside the security boundary.
  defp sanitize(value) do
    value
    |> binary_part(0, min(byte_size(value), @header_log_limit))
    |> :binary.bin_to_list()
    |> Enum.map(&sanitize_byte/1)
    |> List.to_string()
    |> case do
      "" -> "unknown"
      sanitized -> sanitized
    end
  end

  defp sanitize_byte(byte) when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in [?., ?_, ?-], do: byte
  defp sanitize_byte(_byte), do: ??

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, @unauthorized_body)
    |> halt()
  end
end
