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
  belongs inside GitHub's delivery timeout. A duplicate delivery from a retry is
  harmless — `Publisher`'s replay dedup collapses it, which is the same
  mechanism that collapses a webhook against the poller that saw the same event.

  Nothing here may take down the endpoint. A missing event header, an
  unparseable body, and a delivery task that dies are each logged and answered
  with the same 202: refusing the delivery would only earn a retry of a payload
  we already cannot use.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Aiur.Events.GithubWebhook
  alias Plug.Conn

  @accepted_body ~s({"status":"accepted"})

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, _params) do
    dispatch(conn)

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(202, @accepted_body)
  end

  defp dispatch(conn) do
    case {event_type(conn), payload(conn)} do
      {{:ok, event_type}, {:ok, payload}} ->
        deliver(event_type, payload)

      {{:error, :missing_event_type}, _payload} ->
        Logger.warning("[github-webhook] delivery carried no x-github-event header; ignoring")
        :ignored

      {_event_type, {:error, reason}} ->
        Logger.warning("[github-webhook] delivery body unusable reason=#{inspect(reason)}; ignoring")
        :ignored
    end
  end

  defp deliver(event_type, payload) do
    case Application.get_env(:aiur, :github_webhook_deliver_fun) do
      fun when is_function(fun, 2) -> fun.(event_type, payload)
      _unset -> deliver_async(event_type, payload)
    end
  end

  # `start_child/2` rather than `async_nolink/2`: the outcome map is consumed by
  # nobody here, and an unawaited task must not leave a stray reply message in
  # the request process. `handle_delivery/3` already contains its own failures,
  # so a crash here means the supervisor itself is unavailable.
  defp deliver_async(event_type, payload) do
    case Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
           GithubWebhook.handle_delivery(event_type, payload)
         end) do
      {:ok, _pid} ->
        :ok

      other ->
        Logger.error("[github-webhook] could not start delivery task result=#{inspect(other)}")
        :error
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
