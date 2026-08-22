defmodule AiurWeb.GithubWebhookController do
  @moduledoc """
  Receives GitHub webhook deliveries that have already been proven authentic by
  `AiurWeb.GithubWebhook.Auth`, and hands them to
  `Aiur.Events.GithubWebhook.handle_delivery/3` so they normalize onto the same
  topics and payload shapes the polling path produces.

  GitHub abandons a delivery after 10 seconds and retries it, so the action
  acknowledges with 202 *before* the delivery is consumed. Normalizing and
  publishing runs on `Aiur.TaskSupervisor`: the publish tail talks to
  `Aiur.Events.Publisher` and can nudge the orchestrator, neither of which
  belongs inside GitHub's delivery timeout.

  What does run inline, before anything is dispatched, is `Aiur.Webhooks.Ingest`
  — it claims the `X-GitHub-Delivery` id and the payload-derived event key, and
  applies the label-ordering watermark. Admission has to happen here rather than
  in the consumer: the claim is what makes GitHub's at-least-once retries
  harmless, and it must be recorded on the request that actually arrived. A
  dropped delivery is never dispatched, so the normalizer never sees it.

  These are complementary layers, not competing ones. `Publisher`'s replay dedup
  collapses a webhook against the poller that saw the same GitHub event; it is
  in-memory and short. Admission is delivery-level and event-key-level, durable
  across restarts, and bounded by `Aiur.Webhooks.DeliveryLog`'s retention window.

  The admission decision is stashed on the conn under
  `AiurWeb.GithubWebhook.admission_key/0`.

  Every outcome answers 202. A duplicate is a delivery Aiur has already handled,
  so answering anything else would only make GitHub retry it again — and a retry
  is the one thing this subsystem exists to stop producing more of. Nothing here
  may take down the endpoint either: a missing event header, an unparseable
  body, and a delivery task that dies are each logged and answered with the same
  202.

  For the same reason admission runs under its own deadline. The store is a
  single-writer process and its own call timeout is far longer than GitHub's, so
  a wedged store would otherwise hold the response past 10 seconds and turn one
  stalled delivery into an endless retry stream. Past the deadline the receiver
  fails open — admit, dispatch and acknowledge — because a duplicate is
  recoverable and a retry storm is not.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Aiur.Events.GithubWebhook, as: Delivery
  alias Aiur.Webhooks.{DeliveryLog, Ingest}
  alias AiurWeb.GithubWebhook
  alias Plug.Conn

  @accepted_body ~s({"status":"accepted"})

  # Comfortably inside GitHub's 10s abandon-and-retry deadline, leaving room for
  # the body read and signature verification that already ran.
  @admission_timeout_ms 5_000

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, _params) do
    admission = dispatch(conn)

    conn
    |> Conn.put_private(GithubWebhook.admission_key(), admission)
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(202, @accepted_body)
  end

  # Admission first, delivery second: a duplicate has to be dropped *before* the
  # normalizer runs, or the retry GitHub is guaranteed to send would publish the
  # event a second time.
  defp dispatch(conn) do
    case {event_type(conn), payload(conn)} do
      {{:ok, event_type}, {:ok, payload}} ->
        admission = admit(delivery_id(conn), event_type, payload)
        log_admission(admission)

        case admission do
          {:process, decision} -> deliver(event_type, payload, decision.delivery_id)
          {:drop, _reason, _meta} -> :ok
        end

        admission

      {{:error, :missing_event_type}, _payload} ->
        Logger.warning("[github-webhook] delivery carried no x-github-event header; ignoring")
        {:drop, :missing_event_type, %{}}

      {_event_type, {:error, reason}} ->
        Logger.warning("[github-webhook] delivery body unusable reason=#{inspect(reason)}; ignoring")
        {:drop, :unusable_payload, %{reason: reason}}
    end
  end

  defp admit(delivery_id, event_name, payload) do
    store = store()
    task = Task.async(fn -> Ingest.accept(delivery_id, event_name, payload, store: store) end)

    case Task.yield(task, admission_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, admission} ->
        admission

      _timeout_or_exit ->
        Logger.warning("[github-webhook] admission timed out; failing open delivery=#{delivery_id || "unknown"}")
        {:process, %{delivery_id: delivery_id, event: event_name, semantic_key: nil, label_state: nil}}
    end
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

  defp admission_timeout_ms, do: Application.get_env(:aiur, :webhook_admission_timeout_ms, @admission_timeout_ms)

  defp deliver(event_type, payload, delivery_id) do
    case Application.get_env(:aiur, :github_webhook_deliver_fun) do
      fun when is_function(fun, 3) -> fun.(event_type, payload, delivery_id)
      fun when is_function(fun, 2) -> fun.(event_type, payload)
      _unset -> deliver_async(event_type, payload, delivery_id)
    end
  end

  # `start_child/2` rather than `async_nolink/2`: the outcome map is consumed by
  # nobody here, and an unawaited task must not leave a stray reply message in
  # the request process. `handle_delivery/3` already contains its own failures,
  # so a crash here means the supervisor itself is unavailable.
  defp deliver_async(event_type, payload, delivery_id) do
    case Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
           Delivery.handle_delivery(event_type, payload, delivery_id: delivery_id)
         end) do
      {:ok, _pid} ->
        :ok

      other ->
        Logger.error("[github-webhook] could not start delivery task result=#{inspect(other)}")
        :error
    end
  end

  defp delivery_id(conn) do
    case Conn.get_req_header(conn, "x-github-delivery") do
      [value | _rest] -> value
      [] -> nil
    end
  end

  defp event_type(conn) do
    case Conn.get_req_header(conn, "x-github-event") do
      [event_type | _rest] when is_binary(event_type) and event_type != "" -> {:ok, event_type}
      _missing -> {:error, :missing_event_type}
    end
  end

  # GitHub sends either `application/json` — the parsed map is the payload — or
  # `application/x-www-form-urlencoded`, where the JSON body arrives as a single
  # `payload` field. Both content types are configured on the endpoint's parser,
  # so both reach here and both must resolve to the same map.
  #
  # The form branch is gated on the content type rather than on the presence of
  # a `payload` key: a JSON delivery whose body happened to carry a top-level
  # `payload` string would otherwise be decoded as a form and thrown away.
  defp payload(conn) do
    case {form_encoded?(conn), conn.body_params} do
      {true, %{"payload" => encoded}} when is_binary(encoded) -> decode_form_payload(encoded)
      {true, _params} -> {:error, :form_payload_missing}
      {false, %Conn.Unfetched{}} -> {:error, :body_not_parsed}
      {false, params} when is_map(params) -> {:ok, params}
    end
  end

  defp form_encoded?(conn) do
    case Conn.get_req_header(conn, "content-type") do
      [content_type | _rest] -> String.contains?(content_type, "application/x-www-form-urlencoded")
      [] -> false
    end
  end

  defp decode_form_payload(encoded) do
    case Jason.decode(encoded) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _other} -> {:error, :form_payload_not_an_object}
      {:error, _reason} -> {:error, :form_payload_not_json}
    end
  end
end
