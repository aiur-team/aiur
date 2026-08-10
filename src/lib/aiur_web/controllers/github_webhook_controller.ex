defmodule AiurWeb.GithubWebhookController do
  @moduledoc """
  Receives GitHub webhook deliveries that have already been proven authentic by
  `AiurWeb.GithubWebhook.Auth`.

  GitHub abandons a delivery after 10 seconds and retries it, so this action
  acknowledges immediately and does no handler work. What it does do before
  acknowledging is run the delivery through `Aiur.Webhooks.Ingest`, which claims
  the `X-GitHub-Delivery` id and the payload-derived event key. Admission has to
  happen here rather than in the consumer: the claim is what makes GitHub's
  at-least-once retries harmless, and it must be recorded on the request that
  actually arrived.

  The decision is stashed on the conn under
  `AiurWeb.GithubWebhook.admission_key/0`. Consuming an admitted delivery —
  normalizing it onto `Aiur.Events.GithubFirehose` — is a separate change (W-3
  of #1675); until then an admitted delivery is acknowledged and dropped.

  Every outcome answers 202. A duplicate is a delivery Aiur has already handled,
  so answering anything else would only make GitHub retry it again.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Aiur.Webhooks.{DeliveryLog, Ingest}
  alias AiurWeb.GithubWebhook
  alias Plug.Conn

  @accepted_body ~s({"status":"accepted"})

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, params) do
    admission = Ingest.accept(delivery_id(conn), event_name(conn), params, store: store())

    log_admission(admission)

    conn
    |> Conn.put_private(GithubWebhook.admission_key(), admission)
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(202, @accepted_body)
  end

  defp log_admission({:process, admission}) do
    Logger.info("[github-webhook] admitted delivery=#{admission.delivery_id || "unknown"} event=#{admission.event}")
  end

  defp log_admission({:drop, reason, meta}) do
    Logger.info("[github-webhook] dropped reason=#{reason} #{inspect(meta)}")
  end

  # Overridable so a test can point the receiver at its own store rather than
  # the supervised daemon-wide one, matching how the verification plug takes its
  # alert function.
  defp store, do: Application.get_env(:aiur, :webhook_delivery_log, DeliveryLog)

  defp delivery_id(conn), do: header(conn, "x-github-delivery")
  defp event_name(conn), do: header(conn, "x-github-event")

  defp header(conn, name) do
    case Conn.get_req_header(conn, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end
end
